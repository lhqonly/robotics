# Copyright 2026 Tom
#
# Licensed under the MIT License.

"""
Node-level integration tests for the exo_msgs M-A migration (contract v1.7).

These construct the real ExoCmdNode (rclpy) and feed it real exo_msgs/ExoStatus
messages, exercising the adapter paths the rclpy-free tracker tests cannot:

  * payload / seq DECOUPLING -- the tracker pairs on header.seq only; payload may
    be any value (including != seq, negative, extremes) without affecting
    matched / duplicate / unmatched (contract §7.5, core exo_msgs improvement);
  * CRC dual-path (§7.9) -- crc_enabled=True: a bad header.crc bumps
    crc_mismatch_count + WARNs but does NOT block (seq still fed); crc_enabled=
    False: a bad crc is not even checked (counter untouched);
  * CRC end-to-end (Gill Medium-2) -- exo_cmd AND loopback both crc-on, a real
    cmd->echo->verify round trip through the loopback's RE-SIGN path (re-stamp +
    recompute) -> crc_mismatch_count==0. Covers the loopback recompute, not a
    node self-sign;
  * LinkHealth publish (§7.7) -- _on_link_health builds a LinkHealth whose fields
    match the tracker snapshot (counters + RTT stats + reconciles).

rclpy is initialised once per module; each test builds and destroys its own node
so parameter overrides are isolated. No agent / DDS round trip is needed -- we
call the node's callbacks directly with constructed messages.
"""

import contextlib

from exo_cmd.crc import compute_crc
from exo_cmd.exo_cmd_node import ExoCmdNode
from exo_cmd.loopback_node import LoopbackNode
from exo_msgs.msg import ExoCmd, ExoStatus
import pytest
import rclpy
from rclpy.parameter import Parameter


@pytest.fixture(scope='module', autouse=True)
def _rclpy_session():
    rclpy.init()
    yield
    rclpy.shutdown()


@contextlib.contextmanager
def make_node(**param_overrides):
    """Build an ExoCmdNode with params injected, destroy it on exit."""
    overrides = [Parameter(k, value=v) for k, v in param_overrides.items()]
    node = ExoCmdNode(parameter_overrides=overrides)
    try:
        yield node
    finally:
        node.destroy_node()


@contextlib.contextmanager
def make_loopback(crc_enabled=False):
    """
    Build a LoopbackNode, destroy it on exit.

    LoopbackNode.__init__ takes no kwargs (unlike ExoCmdNode), so we set the
    resolved crc switch on the instance after construction rather than plumbing
    a parameter_override through. We exercise the immediate (non-delayed) echo
    path, so delay/drop/duplicate keep their defaults.
    """
    node = LoopbackNode()
    node._crc_enabled = bool(crc_enabled)
    try:
        yield node
    finally:
        node.destroy_node()


def make_status(seq, payload, stamp_mono_ns=0, crc=0):
    """Construct an ExoStatus echo with the given envelope + payload."""
    m = ExoStatus()
    m.header.seq = seq
    m.header.stamp_mono_ns = stamp_mono_ns
    m.header.crc = crc
    m.payload = payload
    return m


# --------------------------------------------------------------------------
# payload / seq decoupling: the tracker pairs on header.seq, never payload.
# --------------------------------------------------------------------------

@pytest.mark.parametrize('payload', [0, 12345, -1, -2 ** 31, 2 ** 31 - 1, 777])
def test_payload_does_not_affect_matching(payload):
    """An echo matches by header.seq regardless of payload value."""
    with make_node(link_health_period_s=0.0, summary_period_s=0.0) as node:
        seq, _ = node._tracker.on_send(node._now())
        # payload deliberately != seq (and sometimes negative / extreme).
        node._on_status(make_status(seq=seq, payload=payload))
        c = node._tracker.counters()
        assert c['matched'] == 1
        assert c['duplicate'] == 0
        assert node._tracker.reconciles()


def test_payload_extremes_do_not_create_false_unmatched():
    """A never-sent seq is unmatched even if its payload mimics a sent seq."""
    with make_node(link_health_period_s=0.0, summary_period_s=0.0) as node:
        seq, _ = node._tracker.on_send(node._now())   # only this seq is sent
        # Echo a DIFFERENT seq but a payload equal to the sent seq: must be
        # unmatched (payload must not launder a never-sent seq into a match).
        node._on_status(make_status(seq=seq + 999, payload=seq))
        c = node._tracker.counters()
        assert c['matched'] == 0
        assert node._tracker.reconciles()


# --------------------------------------------------------------------------
# CRC dual-path (§7.9): enabled = bad crc counted + warned, NOT blocked;
# disabled = bad crc not even checked.
# --------------------------------------------------------------------------

def test_crc_enabled_bad_crc_counts_but_does_not_block():
    """crc_enabled: a mismatched crc bumps the counter but still feeds seq."""
    with make_node(crc_enabled=True, link_health_period_s=0.0,
                   summary_period_s=0.0) as node:
        seq, _ = node._tracker.on_send(node._now())
        # Deliberately wrong crc (0 will not match a non-trivial envelope).
        bad = make_status(seq=seq, payload=42, stamp_mono_ns=123,
                          crc=0xDEADBEEF)
        node._on_status(bad)
        assert node._crc_mismatch_count == 1
        # NOT blocked: the seq was still fed -> matched.
        assert node._tracker.counters()['matched'] == 1
        assert node._tracker.reconciles()


def test_crc_enabled_good_crc_no_mismatch():
    """crc_enabled: a correct crc does not bump the mismatch counter."""
    with make_node(crc_enabled=True, link_health_period_s=0.0,
                   summary_period_s=0.0) as node:
        seq, _ = node._tracker.on_send(node._now())
        stamp, payload = 123, 42
        good = make_status(seq=seq, payload=payload, stamp_mono_ns=stamp,
                           crc=compute_crc(seq, stamp, payload))
        node._on_status(good)
        assert node._crc_mismatch_count == 0
        assert node._tracker.counters()['matched'] == 1


def test_crc_disabled_bad_crc_not_checked():
    """crc_enabled=False (default): a bad crc is ignored, counter untouched."""
    with make_node(crc_enabled=False, link_health_period_s=0.0,
                   summary_period_s=0.0) as node:
        seq, _ = node._tracker.on_send(node._now())
        node._on_status(make_status(seq=seq, payload=42, stamp_mono_ns=123,
                                    crc=0xBADBADBA))
        assert node._crc_mismatch_count == 0     # never checked
        assert node._tracker.counters()['matched'] == 1


def test_crc_end_to_end_loopback_resign_no_mismatch():
    """
    exo_cmd + loopback BOTH crc-on, real round trip -> crc_mismatch_count==0.

    Gill Medium-2 gap: the prior good-crc test (test_crc_enabled_good_crc_no_
    mismatch) signs the ExoStatus itself with compute_crc, so it never exercises
    the LOOPBACK's re-sign path. The MCU/loopback does NOT echo back cmd.crc --
    it RE-STAMPS header.stamp_mono_ns with its own clock and RECOMPUTES the crc
    over that new envelope (loopback_node._publish_echo). This test drives that
    real path end to end:

        exo_cmd._on_timer  -> ExoCmd (crc over t_send envelope)
        loopback._on_heartbeat -> _publish_echo  (re-stamp + RE-COMPUTE crc)
        exo_cmd._on_status -> verifies crc over the re-stamped envelope

    and asserts the verify side sees a clean crc (crc_mismatch_count==0, matched
    bumped). No DDS round trip: we intercept each node's publish() and hand the
    message to the other node's callback, so it runs inside colcon test.
    """
    sent_cmds = []
    echoes = []
    with make_node(crc_enabled=True, link_health_period_s=0.0,
                   summary_period_s=0.0) as cmd, \
            make_loopback(crc_enabled=True) as loop:
        # Intercept both publishers so no DDS is involved.
        cmd._pub.publish = sent_cmds.append
        loop._pub.publish = echoes.append

        # 1) exo_cmd publishes a heartbeat with a crc over ITS t_send envelope.
        cmd._on_timer()
        assert len(sent_cmds) == 1
        out_cmd = sent_cmds[0]
        assert isinstance(out_cmd, ExoCmd)
        # The cmd's own crc is over the send envelope (sanity: it is non-trivial
        # and self-consistent -- the loopback will NOT echo it back verbatim).
        assert out_cmd.header.crc == compute_crc(
            out_cmd.header.seq, out_cmd.header.stamp_mono_ns, out_cmd.payload)

        # 2) loopback receives it and echoes -- RE-STAMPING + RE-COMPUTING crc.
        loop._on_heartbeat(out_cmd)
        assert len(echoes) == 1
        echo = echoes[0]
        assert isinstance(echo, ExoStatus)
        assert echo.header.seq == out_cmd.header.seq          # seq echoed
        # The echo's crc is recomputed over the NEW (re-stamped) envelope; assert
        # it is self-consistent with the echo's own (re-stamped) stamp. We do
        # NOT assert the stamp differs from the cmd's (two monotonic_ns reads
        # microseconds apart -- effectively always distinct, but asserting it
        # would couple the test to clock resolution). Self-consistency of the
        # recomputed crc is the load-bearing property.
        assert echo.header.crc == compute_crc(
            echo.header.seq, echo.header.stamp_mono_ns, echo.payload)

        # 3) exo_cmd verifies the echo's crc over the re-stamped envelope: the
        #    loopback re-sign path is the one being covered, NOT a node self-sign.
        cmd._on_status(echo)
        assert cmd._crc_mismatch_count == 0      # Medium-2: clean round trip
        assert cmd._tracker.counters()['matched'] == 1
        assert cmd._tracker.reconciles()


# --------------------------------------------------------------------------
# LinkHealth publish (§7.7): _on_link_health snapshot matches the tracker.
# --------------------------------------------------------------------------

def test_link_health_message_matches_tracker_snapshot():
    """The published LinkHealth fields equal the tracker counters + RTT stats."""
    captured = []
    with make_node(link_health_period_s=0.0, summary_period_s=0.0) as node:
        # Drive a known mix: 2 matched (with RTT), 1 duplicate, 1 unmatched.
        s0, _ = node._tracker.on_send(0.0)
        s1, _ = node._tracker.on_send(0.0)
        node._tracker.on_echo(s0, 0.010)         # matched, 10 ms
        node._tracker.on_echo(s1, 0.020)         # matched, 20 ms
        node._tracker.on_echo(s0, 0.030)         # duplicate
        node._tracker.on_echo(10 ** 9, 0.040)    # unmatched (never sent)

        # Intercept the publish so no DDS round trip is required.
        node._health_pub.publish = captured.append
        node._on_link_health()

    assert len(captured) == 1
    msg = captured[0]
    # The LinkHealth fields must equal the tracker snapshot the node packed.
    assert msg.sent == 2
    assert msg.matched == 2
    assert msg.lost == 0
    assert msg.duplicate == 1
    assert msg.stale_duplicate == 0
    assert msg.inflight == 0
    assert msg.reconciles is True
    # RTT stats: last matched was 20 ms; max 20; p95 over [10,20] nearest-rank
    # ceil(0.95*2)=2 -> 20.0.
    assert msg.rtt_last_ms == 20.0
    assert msg.rtt_max_ms == 20.0
    assert msg.rtt_p95_ms == 20.0
    # Header stamp is wall-clock (diagnostic only); just assert it is set.
    assert msg.header.stamp.sec != 0 or msg.header.stamp.nanosec != 0
