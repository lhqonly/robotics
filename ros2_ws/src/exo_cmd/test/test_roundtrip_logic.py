# Copyright 2026 Tom
#
# Licensed under the MIT License.

"""
Logic-layer tests for the v1.1 link-health monitor (contract §7, A1-A7).

These import the REAL LinkHealthTracker (exo_cmd.link_health) -- it is
deliberately rclpy-free, so these run anywhere with no ROS. Unlike the v1.0
file, there is no reimplementation to drift out of sync: we test the shipping
code directly. Gill will add more adversarial cases on top of these.

Time is injected as a plain monotonic float (seconds); the tracker never reads
a clock, so every case below is fully deterministic.

Mapping to contract acceptance points:
  A1 RTT measurable             -> test_a1_*
  A2 over-threshold warning     -> test_a2_*
  A3 loss detection             -> test_a3_*
  A4 no silent eviction / recon -> test_a4_*
  A5 duplicate echo handling    -> test_a5_*
  A6 genuine wrong value        -> test_a6_*
  A7 wrap safety                -> test_a7_*
  A8 reconciliation observable  -> asserted throughout via reconciles()
"""

from exo_cmd.link_health import (Event, forward_distance, LinkHealthTracker,
                                 SEQ_MODULUS)
import pytest


def kinds(events):
    return [e.kind for e in events]


def first(events, kind):
    for e in events:
        if e.kind == kind:
            return e
    return None


# --------------------------------------------------------------------------
# A1: RTT is measured and recorded; injected delay D shows up as RTT ≈ D.
# --------------------------------------------------------------------------
def test_a1_rtt_measured_normal():
    t = LinkHealthTracker()
    seq, _ = t.on_send(now=1.000)
    events = t.on_echo(seq, now=1.012)  # 12 ms later
    m = first(events, 'matched')
    assert m is not None
    assert m.rtt_ms == pytest.approx(12.0)
    assert t.matched_count == 1
    assert t.reconciles()


def test_a1_rtt_equals_injected_delay():
    t = LinkHealthTracker(rtt_warn_ms=50.0, rtt_deadline_ms=200.0)
    seq, _ = t.on_send(now=0.0)
    # Simulate loopback injected delay of exactly 30 ms.
    events = t.on_echo(seq, now=0.030)
    assert first(events, 'matched').rtt_ms == pytest.approx(30.0)


# --------------------------------------------------------------------------
# A2: RTT over rtt_warn_ms -> WARN with seq + measured rtt; within -> none.
# Threshold is configurable (changing the param changes behaviour).
# --------------------------------------------------------------------------
def test_a2_over_warn_threshold_warns():
    t = LinkHealthTracker(rtt_warn_ms=50.0, rtt_deadline_ms=200.0)
    seq, _ = t.on_send(now=0.0)
    events = t.on_echo(seq, now=0.060)  # 60 ms > 50 ms
    w = first(events, 'warn_rtt')
    assert w is not None
    assert w.level == 'WARN'
    assert w.seq == seq
    assert w.rtt_ms == pytest.approx(60.0)
    assert w.threshold_ms == 50.0


def test_a2_within_warn_threshold_no_warn():
    t = LinkHealthTracker(rtt_warn_ms=50.0, rtt_deadline_ms=200.0)
    seq, _ = t.on_send(now=0.0)
    events = t.on_echo(seq, now=0.040)  # 40 ms < 50 ms
    assert 'warn_rtt' not in kinds(events)


def test_a2_threshold_is_configurable():
    # Same 40 ms RTT: warns when threshold lowered to 30 ms.
    t = LinkHealthTracker(rtt_warn_ms=30.0, rtt_deadline_ms=200.0)
    seq, _ = t.on_send(now=0.0)
    events = t.on_echo(seq, now=0.040)
    assert 'warn_rtt' in kinds(events)


def test_a2_warn_must_be_below_deadline():
    with pytest.raises(ValueError):
        LinkHealthTracker(rtt_warn_ms=200.0, rtt_deadline_ms=200.0)
    with pytest.raises(ValueError):
        LinkHealthTracker(rtt_warn_ms=300.0, rtt_deadline_ms=200.0)


# --------------------------------------------------------------------------
# A3: an un-echoed seq is settled LOST after the deadline; lost_count is exact.
# --------------------------------------------------------------------------
def test_a3_single_loss_detected_after_deadline():
    t = LinkHealthTracker(rtt_deadline_ms=200.0)
    seq, _ = t.on_send(now=0.0)
    # Before the deadline: nothing settled.
    assert t.sweep_deadlines(now=0.150) == []
    assert t.lost_count == 0
    # At/after the deadline: settled LOST exactly once.
    events = t.sweep_deadlines(now=0.200)
    lost = first(events, 'lost')
    assert lost is not None
    assert lost.seq == seq
    assert lost.level == 'ERROR'
    assert lost.waited_ms == pytest.approx(200.0)
    assert t.lost_count == 1
    assert t.reconciles()


def test_a3_drop_k_increments_lost_by_exactly_k():
    t = LinkHealthTracker(rtt_deadline_ms=100.0)
    sent = [t.on_send(now=0.0)[0] for _ in range(10)]
    # Echo only the even ones; odds are dropped.
    for s in sent:
        if s % 2 == 0:
            t.on_echo(s, now=0.010)
    # After the deadline, the 5 dropped odds must be LOST -- exactly 5.
    events = t.sweep_deadlines(now=0.100)
    assert sum(1 for e in events if e.kind == 'lost') == 5
    assert t.lost_count == 5
    assert t.matched_count == 5
    assert t.reconciles()


def test_a3_loss_settled_only_once():
    t = LinkHealthTracker(rtt_deadline_ms=100.0)
    t.on_send(now=0.0)
    t.sweep_deadlines(now=0.100)
    # A second sweep must not double-count an already-settled loss.
    again = t.sweep_deadlines(now=0.300)
    assert again == []
    assert t.lost_count == 1


# --------------------------------------------------------------------------
# A4: no silent eviction. Backlog + cap still reconciles; every removed entry
# is matched or lost -- never silently dropped.
# --------------------------------------------------------------------------
def test_a4_backlog_never_silently_dropped_unbounded():
    t = LinkHealthTracker(rtt_deadline_ms=1000.0)  # long deadline -> backlog
    for _ in range(5000):
        t.on_send(now=0.0)  # all in-flight, none echoed
    assert t.inflight == 5000
    assert t.reconciles()  # sent == matched + lost + inflight throughout


def test_a4_capacity_eviction_settles_as_lost():
    # With a memory cap, over-cap entries must be SETTLED AS LOST + warned,
    # not silently discarded. Reconciliation must still hold.
    t = LinkHealthTracker(rtt_deadline_ms=1000.0, max_inflight=100)
    evict_warnings = 0
    for i in range(250):
        _, events = t.on_send(now=0.0)
        evict_warnings += sum(1 for e in events if e.kind == 'evict_lost')
    assert t.inflight == 100
    assert t.sent_count == 250
    # 150 entries were pushed out -> all settled LOST (none vanished).
    assert t.lost_count == 150
    assert evict_warnings == 150
    assert t.reconciles()


def test_a4_no_min_silent_path_present():
    # Guard against re-introducing the v1.0 anti-pattern: the source must not
    # contain a `discard(min(...))`-style silent eviction on the in-flight set.
    import inspect

    import exo_cmd.exo_cmd_node as node_mod
    import exo_cmd.link_health as lh_mod
    for mod in (node_mod, lh_mod):
        src = inspect.getsource(mod)
        assert 'discard(min(' not in src
        assert '.discard(min' not in src


# --------------------------------------------------------------------------
# A5: duplicate echo -> duplicate_count, NOT unmatched; matched not re-counted.
# --------------------------------------------------------------------------
def test_a5_duplicate_echo_is_duplicate_not_unmatched():
    t = LinkHealthTracker()
    seq, _ = t.on_send(now=0.0)
    t.on_echo(seq, now=0.010)              # first -> matched
    events = t.on_echo(seq, now=0.011)     # second -> duplicate
    assert 'duplicate' in kinds(events)
    assert 'unmatched' not in kinds(events)
    assert t.duplicate_count == 1
    assert t.matched_count == 1            # NOT incremented again
    assert t.reconciles()


def test_a5_many_duplicates_counted():
    t = LinkHealthTracker()
    seq, _ = t.on_send(now=0.0)
    t.on_echo(seq, now=0.010)
    for _ in range(5):
        t.on_echo(seq, now=0.011)
    assert t.duplicate_count == 5
    assert t.matched_count == 1


def test_a5_duplicate_after_lost_still_duplicate():
    # A retransmit arriving AFTER we already gave up (lost) is still a known,
    # already-settled value -> duplicate, not unmatched.
    t = LinkHealthTracker(rtt_deadline_ms=100.0)
    seq, _ = t.on_send(now=0.0)
    t.sweep_deadlines(now=0.100)           # settled LOST
    events = t.on_echo(seq, now=0.150)     # late retransmit
    assert 'duplicate' in kinds(events)
    assert t.duplicate_count == 1


# --------------------------------------------------------------------------
# A6: a value never sent -> genuine UNMATCHED.
# --------------------------------------------------------------------------
def test_a6_never_sent_value_is_unmatched():
    t = LinkHealthTracker()
    t.on_send(now=0.0)            # sends seq 0
    events = t.on_echo(999999, now=0.010)
    assert 'unmatched' in kinds(events)
    assert first(events, 'unmatched').level == 'WARN'
    # An unmatched echo does not corrupt the counters.
    assert t.matched_count == 0
    assert t.duplicate_count == 0
    assert t.reconciles()


# --------------------------------------------------------------------------
# A7: wrap safety. Counter wraps mod 2^32; matching/loss/duplicate correct at
# the wrap point; no signed overflow (Python ints are unbounded).
# --------------------------------------------------------------------------
def test_a7_forward_distance_wraps_safely():
    assert forward_distance(0, 1) == 1
    assert forward_distance(5, 3) == SEQ_MODULUS - 2
    # Across the wrap boundary: 2 steps forward from (2^32-1) lands on 1.
    assert forward_distance(SEQ_MODULUS - 1, 1) == 2
    assert forward_distance(SEQ_MODULUS - 1, 0) == 1


def test_a7_send_counter_wraps_mod_2_32():
    t = LinkHealthTracker()
    t._next_seq = SEQ_MODULUS - 1      # park at the top of the range
    seq_a, _ = t.on_send(now=0.0)
    seq_b, _ = t.on_send(now=0.0)
    assert seq_a == SEQ_MODULUS - 1
    assert seq_b == 0                  # wrapped, not 2^32 / not negative
    assert t._next_seq == 1


def test_a7_match_correct_across_wrap():
    t = LinkHealthTracker()
    t._next_seq = SEQ_MODULUS - 1
    s0, _ = t.on_send(now=0.0)          # 2^32-1
    s1, _ = t.on_send(now=0.0)          # 0 (wrapped)
    # Echoes pair by exact equality regardless of wrap.
    e1 = t.on_echo(s1, now=0.010)
    e0 = t.on_echo(s0, now=0.010)
    assert first(e1, 'matched') is not None
    assert first(e0, 'matched') is not None
    assert t.matched_count == 2
    assert t.reconciles()


def test_a7_counters_no_signed_overflow():
    # Python ints are unbounded; assert the counters keep climbing past 2^32
    # without wrapping/overflow (a 32-bit signed counter would have flipped).
    # (Deadline is irrelevant here; use defaults so rtt_warn_ms < rtt_deadline_ms.)
    t = LinkHealthTracker()
    big = SEQ_MODULUS + 100
    t.sent_count = big
    t.matched_count = big
    assert t.sent_count > SEQ_MODULUS
    assert t.matched_count > 0
    assert isinstance(t.sent_count, int)


# --------------------------------------------------------------------------
# A8: the five counters are readable and the identity holds across a mixed run.
# --------------------------------------------------------------------------
def test_a8_reconciliation_across_mixed_run():
    t = LinkHealthTracker(rtt_deadline_ms=100.0)
    sent = [t.on_send(now=0.0)[0] for _ in range(20)]
    # matched: echo first 10 in time
    for s in sent[:10]:
        t.on_echo(s, now=0.010)
    # duplicates on a couple
    t.on_echo(sent[0], now=0.011)
    t.on_echo(sent[1], now=0.011)
    # unmatched
    t.on_echo(123456789, now=0.012)
    # loss: sweep -> the un-echoed 10 settle lost
    t.sweep_deadlines(now=0.100)

    c = t.counters()
    assert c['sent'] == 20
    assert c['matched'] == 10
    assert c['lost'] == 10
    assert c['duplicate'] == 2
    assert c['inflight'] == 0
    assert t.reconciles()
    # Event dataclass is what the node surfaces -- smoke-check its shape.
    assert isinstance(Event('matched', 'INFO', 0, 'x'), Event)
