# Copyright 2026 Tom
#
# Licensed under the MIT License.

"""
Rolling-window RTT stats for the exo_msgs M-A tracker (contract §7.7).

Logic-layer tests (rclpy-free): drive a known RTT sequence through the real
LinkHealthTracker via on_send/on_echo with injected monotonic times, and assert
rtt_stats() reports the expected rtt_last_ms / rtt_p95_ms / rtt_max_ms, that the
window is bounded (old samples evicted), and that an empty window gives the
deterministic placeholder.
"""

import math

from exo_cmd.link_health import (LinkHealthTracker, RTT_EMPTY_PLACEHOLDER)
import pytest


def _feed_rtt(t, rtt_ms_list, base=0.0):
    """
    Send + echo each entry so the matched RTT equals the given value (ms).

    RTT is derived as (t_recv - t_send) * 1000, which incurs tiny float error,
    so callers compare with pytest.approx.
    """
    for i, rtt in enumerate(rtt_ms_list):
        t0 = base + i  # space sends 1 s apart so deadlines never expire
        seq, _ = t.on_send(now=t0)
        t.on_echo(seq, now=t0 + rtt / 1000.0)


def test_empty_window_gives_placeholder():
    """Before any matched echo, all three RTT stats are the placeholder."""
    t = LinkHealthTracker(rtt_deadline_ms=1e9)
    r = t.rtt_stats()
    assert r['rtt_last_ms'] == RTT_EMPTY_PLACEHOLDER
    assert r['rtt_p95_ms'] == RTT_EMPTY_PLACEHOLDER
    assert r['rtt_max_ms'] == RTT_EMPTY_PLACEHOLDER


def test_single_sample_last_p95_max_all_equal():
    """One matched echo: last == p95 == max == that RTT."""
    t = LinkHealthTracker(rtt_deadline_ms=1e9, rtt_warn_ms=1e8)
    _feed_rtt(t, [12.5])
    r = t.rtt_stats()
    assert r['rtt_last_ms'] == pytest.approx(12.5)
    assert r['rtt_p95_ms'] == pytest.approx(12.5)
    assert r['rtt_max_ms'] == pytest.approx(12.5)


def test_known_sequence_last_p95_max():
    """
    A known RTT sequence yields the expected last / nearest-rank p95 / max.

    Feed RTTs 1..100 ms in order. last is the final value (100), max is 100, and
    nearest-rank p95 over n=100 is the ceil(0.95*100)=95th smallest = 95.0.
    """
    t = LinkHealthTracker(rtt_deadline_ms=1e9, rtt_warn_ms=1e8)
    seq_rtts = [float(x) for x in range(1, 101)]   # 1.0 .. 100.0
    _feed_rtt(t, seq_rtts)
    r = t.rtt_stats()
    assert r['rtt_last_ms'] == pytest.approx(100.0)
    assert r['rtt_max_ms'] == pytest.approx(100.0)
    # nearest-rank: ceil(0.95 * 100) = 95 -> the 95th smallest = 95.0
    assert r['rtt_p95_ms'] == pytest.approx(95.0)


def test_p95_nearest_rank_small_n():
    """nearest-rank p95 on a tiny window picks ceil(0.95*n)-th smallest."""
    t = LinkHealthTracker(rtt_deadline_ms=1e9, rtt_warn_ms=1e8)
    _feed_rtt(t, [10.0, 20.0, 30.0])   # n=3 -> ceil(2.85)=3 -> 30.0
    r = t.rtt_stats()
    assert r['rtt_p95_ms'] == pytest.approx(30.0)
    assert r['rtt_max_ms'] == pytest.approx(30.0)
    assert r['rtt_last_ms'] == pytest.approx(30.0)


def test_window_is_bounded_old_samples_evicted():
    """
    Window of size N keeps only the last N RTTs; older ones are evicted.

    Feed N huge RTTs then N small ones with rtt_window=N. After the small batch,
    max and p95 must reflect ONLY the small samples (the huge ones aged out),
    proving the deque is bounded. rtt_last_ms is the truly-latest sample.
    """
    n = 8
    t = LinkHealthTracker(rtt_deadline_ms=1e9, rtt_warn_ms=1e8, rtt_window=n)
    _feed_rtt(t, [1000.0] * n, base=0.0)          # fill with big values
    _feed_rtt(t, [float(x) for x in range(1, n + 1)], base=100.0)  # 1..n small
    r = t.rtt_stats()
    assert r['rtt_max_ms'] == pytest.approx(float(n))            # 1000s all evicted
    assert r['rtt_last_ms'] == pytest.approx(float(n))
    # nearest-rank p95 over the small window 1..n
    rank = math.ceil(0.95 * n)
    assert r['rtt_p95_ms'] == pytest.approx(float(rank))


def test_rtt_last_survives_window_eviction():
    """
    rtt_last_ms always reflects the most recent matched RTT.

    Even after the latest sample would be the only one of its kind, rtt_last_ms
    tracks it independently of window contents.
    """
    t = LinkHealthTracker(rtt_deadline_ms=1e9, rtt_warn_ms=1e8, rtt_window=2)
    _feed_rtt(t, [5.0, 6.0, 7.0])     # window keeps [6,7]; last is 7
    r = t.rtt_stats()
    assert r['rtt_last_ms'] == pytest.approx(7.0)
    assert r['rtt_max_ms'] == pytest.approx(7.0)     # only 6,7 in window


def test_rtt_window_not_fed_by_lost_or_duplicate():
    """Only matched echoes feed the RTT window (loss / duplicate do not)."""
    t = LinkHealthTracker(rtt_deadline_ms=100.0, rtt_warn_ms=50.0)
    # one matched at 10 ms RTT
    s0, _ = t.on_send(now=0.0)
    t.on_echo(s0, now=0.010)
    # one lost (never echoed) -> sweep settles it; must not touch RTT window
    s1, _ = t.on_send(now=0.0)
    t.sweep_deadlines(now=0.200)
    # a duplicate of s0 -> must not push a new RTT sample
    t.on_echo(s0, now=0.300)
    r = t.rtt_stats()
    assert r['rtt_last_ms'] == pytest.approx(10.0)
    assert r['rtt_max_ms'] == pytest.approx(10.0)
    assert t.lost_count == 1
    assert t.duplicate_count == 1
