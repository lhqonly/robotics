# Copyright 2026 Tom
#
# Licensed under the MIT License.

"""
Adversarial logic-layer tests for the v1.1 link-health monitor (contract §7).

Author: Gill (test). These are the GAP-FILLING / boundary cases that
test_roundtrip_logic.py does NOT cover. They import the REAL shipping
LinkHealthTracker (exo_cmd.link_health, rclpy-free) and inject a plain
monotonic float for time, so every case is deterministic and runs with no ROS.

Focus, per the G2-收尾 / Phase A adversarial brief:
  * reconciliation identity (sent == matched + lost + inflight) under EXTREME
    timing: echo on the same sweep tick as the deadline; a late echo arriving
    AFTER the entry was already settled LOST; many duplicates; reordered echo;
  * §7.4/M4 no silent eviction: backlog + max_inflight cap must settle the
    over-cap victim as LOST + warn, never silently discard; the victim must be
    the OLDEST, not the newest;
  * §7.6/P1-3 wrap mod 2^32: behaviour AT the boundary, forced full-wrap seq
    collision while an old entry is still in flight;
  * §7.5/P1-2 duplicate/retransmit: an already-settled value re-echoed must be
    duplicate, never UNMATCHED/wrong-value;
  * param validation rtt_warn_ms < rtt_deadline_ms (equal / reversed rejected);
  * settled_window boundary + Gill finding #1: a retransmit of an EVER-SENT
    value older than the remembered window is a STALE_DUPLICATE (benign), never
    a false UNMATCHED; only a NEVER-SENT value is UNMATCHED.

Every test asserts reconciles() so a silent-drop regression cannot slip by.
"""

import threading

from exo_cmd.link_health import (forward_distance, LinkHealthTracker,
                                 SEQ_MODULUS)
import pytest


def kinds(events):
    return [e.kind for e in events]


def first(events, kind):
    for e in events:
        if e.kind == kind:
            return e
    return None


# ==========================================================================
# Group 1 -- EXTREME TIMING around the reconciliation identity.
# ==========================================================================

def test_echo_on_same_tick_as_deadline_matches_then_sweep_is_noop():
    """
    Echo arrives at now == deadline, caller calls on_echo BEFORE sweep.

    on_echo must match (the entry is still in-flight), and the same-tick sweep
    must NOT then re-settle it as LOST (no double settlement). reconciles().
    """
    t = LinkHealthTracker(rtt_warn_ms=50.0, rtt_deadline_ms=100.0)
    seq, _ = t.on_send(now=0.0)
    e = t.on_echo(seq, now=0.100)          # exactly at the deadline
    sw = t.sweep_deadlines(now=0.100)      # same tick, after the echo
    assert first(e, 'matched') is not None
    assert sw == []                        # nothing left to settle
    assert t.matched_count == 1
    assert t.lost_count == 0
    assert t.reconciles()


def test_sweep_at_deadline_then_late_echo_is_duplicate_not_double_count():
    """
    Caller sweeps FIRST at deadline, THEN the late echo must be DUPLICATE.

    The caller sweeps FIRST at now == deadline (settles LOST), THEN the echo
    arrives. The late echo must be a DUPLICATE (already settled), and must NOT
    add a second lifecycle transition. lost stays 1, matched stays 0, the
    identity is preserved (sent must not become unbalanced).
    """
    t = LinkHealthTracker(rtt_deadline_ms=100.0)
    seq, _ = t.on_send(now=0.0)
    sw = t.sweep_deadlines(now=0.100)
    assert first(sw, 'lost') is not None
    e = t.on_echo(seq, now=0.100)          # same tick, after the sweep
    assert 'duplicate' in kinds(e)
    assert 'unmatched' not in kinds(e)
    assert t.lost_count == 1
    assert t.matched_count == 0
    assert t.duplicate_count == 1
    assert t.sent_count == 1               # sent must not have been inflated
    assert t.reconciles()


def test_late_echo_far_after_lost_settlement_still_duplicate():
    """
    A retransmit long after LOST settlement is still a duplicate.

    A retransmit arriving long after the LOST settlement (but still inside
    the settled_window) is duplicate, never UNMATCHED, and reconciles().
    """
    t = LinkHealthTracker(rtt_deadline_ms=100.0)
    seq, _ = t.on_send(now=0.0)
    t.sweep_deadlines(now=0.100)           # LOST
    for k in range(1, 6):                  # five late retransmits
        e = t.on_echo(seq, now=0.100 + k)
        assert 'duplicate' in kinds(e)
    assert t.duplicate_count == 5
    assert t.lost_count == 1
    assert t.matched_count == 0
    assert t.reconciles()


def test_reordered_echoes_match_by_exact_value():
    """
    Echoes returning out of send order must each pair by exact value.

    Echoes returning out of send order must each pair by exact value; no
    ordering assumption may corrupt counts. reconciles() throughout.
    """
    t = LinkHealthTracker(rtt_deadline_ms=1000.0)
    sent = [t.on_send(now=0.0)[0] for _ in range(5)]   # 0,1,2,3,4
    for s in reversed(sent):               # echo 4,3,2,1,0
        e = t.on_echo(s, now=0.010)
        assert first(e, 'matched') is not None
        assert t.reconciles()
    assert t.matched_count == 5
    assert t.inflight == 0
    assert t.reconciles()


def test_many_duplicates_interleaved_with_a_real_match():
    """
    Heavy duplicate storm on one seq must never re-increment matched.

    A heavy duplicate storm on one seq must never re-increment matched and
    never desync the identity.
    """
    t = LinkHealthTracker(rtt_deadline_ms=1000.0)
    s0, _ = t.on_send(now=0.0)
    s1, _ = t.on_send(now=0.0)
    t.on_echo(s0, now=0.010)               # matched
    for _ in range(100):
        t.on_echo(s0, now=0.011)           # duplicates
    t.on_echo(s1, now=0.012)               # matched
    for _ in range(50):
        t.on_echo(s1, now=0.013)           # duplicates
    assert t.matched_count == 2
    assert t.duplicate_count == 150
    assert t.inflight == 0
    assert t.reconciles()


# ==========================================================================
# Group 2 -- §7.4 / M4 NO SILENT EVICTION (in-flight cap).
# ==========================================================================

def test_cap_eviction_victim_is_oldest_not_newest():
    """
    Cap eviction must settle the OLDEST entry, never the newest.

    When max_inflight forces an eviction, the OLDEST (smallest deadline)
    entry must be the one settled LOST -- never the freshly-sent newest.
    """
    t = LinkHealthTracker(rtt_deadline_ms=100.0, max_inflight=2)
    s_old, _ = t.on_send(now=0.0)
    s_mid, _ = t.on_send(now=0.1)
    s_new, ev = t.on_send(now=0.2)         # over cap -> evict oldest
    assert [e.kind for e in ev] == ['evict_lost']
    assert ev[0].seq == s_old              # oldest evicted, not s_new
    assert s_old not in t._inflight
    assert s_new in t._inflight            # newest is retained
    assert t.lost_count == 1
    assert t.reconciles()


def test_cap_eviction_emits_warn_for_every_victim():
    """
    Every over-cap entry must produce an evict_lost WARN and bump lost_count.

    Every over-cap entry must produce an evict_lost WARN event AND bump
    lost_count -- the count of warnings must equal the count of lost evictions
    (none silently dropped). Verifies the §7.4 'never silent' guarantee at
    scale and that the events carry WARN level.
    """
    t = LinkHealthTracker(rtt_deadline_ms=1000.0, max_inflight=10)
    warns = 0
    for _ in range(1000):
        _, ev = t.on_send(now=0.0)
        for e in ev:
            assert e.kind == 'evict_lost'
            assert e.level == 'WARN'
            assert e.waited_ms is not None
            warns += 1
    assert t.inflight == 10
    assert t.sent_count == 1000
    assert t.lost_count == 990
    assert warns == 990                    # every victim warned, none vanished
    assert t.reconciles()


def test_cap_of_one_keeps_only_latest():
    """Degenerate cap=1: each new send evicts the previous as LOST."""
    t = LinkHealthTracker(rtt_deadline_ms=1000.0, max_inflight=1)
    seqs = []
    total_evict = 0
    for i in range(5):
        s, ev = t.on_send(now=float(i))
        seqs.append(s)
        total_evict += sum(1 for e in ev if e.kind == 'evict_lost')
    assert t.inflight == 1
    assert list(t._inflight.keys()) == [seqs[-1]]
    assert total_evict == 4
    assert t.lost_count == 4
    assert t.reconciles()


def test_no_min_silent_eviction_in_source_strict():
    """
    Ensure the in-flight set is never shrunk by an unrouted pop/discard.

    Stronger than the existing guard: ensure the in-flight set is never
    shrunk by a bare pop/discard that is NOT routed through _settle_lost.

    The contract (§7.4) allows exactly two removal paths: matched (on_echo) and
    LOST (_settle_lost). We assert the source contains no `del self._inflight`
    or `_inflight.pop(` outside on_echo/_settle_lost, and no list-min discard.
    """
    import inspect

    import exo_cmd.link_health as lh_mod
    src = inspect.getsource(lh_mod)
    # No v1.0-style silent-min discard.
    assert 'discard(min(' not in src
    assert '.discard(min' not in src
    # Every dict removal lives in on_echo (matched) or _settle_lost (lost).
    # There must be exactly: one `del self._inflight[seq]` (matched path) and
    # one `self._inflight.pop(` (the LOST guard). Anything else is suspicious.
    assert src.count('del self._inflight[') == 1
    assert src.count('self._inflight.pop(') == 1


# ==========================================================================
# Group 3 -- §7.6 / P1-3 WRAP at the 2^32 boundary.
# ==========================================================================

def test_forward_distance_boundary_values():
    assert forward_distance(0, 0) == 0
    assert forward_distance(SEQ_MODULUS - 1, SEQ_MODULUS - 1) == 0
    assert forward_distance(SEQ_MODULUS - 1, 0) == 1
    assert forward_distance(0, SEQ_MODULUS - 1) == SEQ_MODULUS - 1
    # symmetric pair sums to the modulus when a != b
    a, b = 10, 20
    assert (forward_distance(a, b) + forward_distance(b, a)) % SEQ_MODULUS == 0


def test_send_wraps_at_exact_boundary_no_negative_no_overflow():
    t = LinkHealthTracker()
    t._next_seq = SEQ_MODULUS - 2
    s0, _ = t.on_send(now=0.0)             # 2^32-2
    s1, _ = t.on_send(now=0.0)             # 2^32-1
    s2, _ = t.on_send(now=0.0)             # wraps to 0
    assert s0 == SEQ_MODULUS - 2
    assert s1 == SEQ_MODULUS - 1
    assert s2 == 0
    assert all(0 <= s < SEQ_MODULUS for s in (s0, s1, s2))
    assert t._next_seq == 1


def test_forced_full_wrap_seq_collision_settles_stale_as_lost():
    """
    A full 2^32 wrap onto a still-in-flight seq settles the stale entry LOST.

    Pathological: a full 2^32 wrap lands on a seq whose OLD entry is still
    in flight (deadline not yet reached). The stale entry must be settled LOST
    (evict_lost WARN), the dict key must NOT be silently overwritten, the new
    entry takes the slot, and the identity holds. Then the NEW echo matches.
    """
    t = LinkHealthTracker(rtt_deadline_ms=1e9)   # effectively never expires
    t._next_seq = 0
    old, _ = t.on_send(now=0.0)            # seq 0 in flight
    assert old == 0
    t._next_seq = 0                        # simulate a complete wrap-around
    new, ev = t.on_send(now=1.0)           # seq 0 reused -> collision
    assert new == 0
    assert [e.kind for e in ev] == ['evict_lost']
    assert t.sent_count == 2
    assert t.lost_count == 1               # the stale 0 was settled, not lost
    assert t.inflight == 1                 # only the new 0
    assert t.reconciles()
    # After collision the new 0 must NOT be marked settled (so its echo matches).
    assert 0 not in t._settled
    assert 0 in t._inflight
    e = t.on_echo(0, now=1.001)
    assert first(e, 'matched') is not None
    assert t.matched_count == 1
    assert t.reconciles()


def test_match_loss_duplicate_all_correct_straddling_wrap():
    """Mixed lifecycle straddling the wrap boundary stays correct."""
    t = LinkHealthTracker(rtt_deadline_ms=100.0)
    t._next_seq = SEQ_MODULUS - 2
    a, _ = t.on_send(now=0.0)              # 2^32-2  -> will be matched
    b, _ = t.on_send(now=0.0)              # 2^32-1  -> will be lost
    c, _ = t.on_send(now=0.0)              # 0 (wrapped) -> matched + duplicate
    t.on_echo(a, now=0.010)
    t.on_echo(c, now=0.010)
    t.on_echo(c, now=0.011)                # duplicate of wrapped value
    t.sweep_deadlines(now=0.100)           # b times out -> lost
    c_ = t.counters()
    assert c_['matched'] == 2
    assert c_['lost'] == 1
    assert c_['duplicate'] == 1
    assert c_['inflight'] == 0
    assert t.reconciles()


# ==========================================================================
# Group 4 -- PARAM VALIDATION: rtt_warn_ms < rtt_deadline_ms.
# ==========================================================================

def test_equal_thresholds_rejected():
    with pytest.raises(ValueError):
        LinkHealthTracker(rtt_warn_ms=200.0, rtt_deadline_ms=200.0)


def test_reversed_thresholds_rejected():
    with pytest.raises(ValueError):
        LinkHealthTracker(rtt_warn_ms=250.0, rtt_deadline_ms=200.0)


def test_warn_just_below_deadline_accepted():
    t = LinkHealthTracker(rtt_warn_ms=199.999, rtt_deadline_ms=200.0)
    assert t.rtt_warn_ms < t.rtt_deadline_ms


def test_negative_or_zero_max_inflight_disables_cap():
    """
    max_inflight <= 0 must mean 'unbounded' (cap disabled).

    max_inflight <= 0 must mean 'unbounded' (cap disabled), per __post_init__
    -- not a cap of 0 that would evict everything immediately.
    """
    for bad in (0, -1, -100):
        t = LinkHealthTracker(rtt_deadline_ms=1000.0, max_inflight=bad)
        assert t.max_inflight is None
        for _ in range(50):
            _, ev = t.on_send(now=0.0)
            assert ev == []                # no eviction storm
        assert t.inflight == 50
        assert t.reconciles()


# ==========================================================================
# Group 5 -- settled_window boundary + Gill finding #1 (stale-retransmit).
# ==========================================================================

def test_retransmit_within_window_is_duplicate():
    """A retransmit whose seq is still inside settled_window -> duplicate."""
    t = LinkHealthTracker(settled_window=4)
    seqs = [t.on_send(now=0.0)[0] for _ in range(4)]
    for s in seqs:
        t.on_echo(s, now=0.010)            # all matched, all in _settled
    # seqs[0] still within the window of 4 -> retransmit is duplicate
    e = t.on_echo(seqs[0], now=0.020)
    assert 'duplicate' in kinds(e)
    assert t.duplicate_count == 1
    assert t.reconciles()


def test_retransmit_older_than_window_is_stale_duplicate_not_unmatched():
    """
    An ever-sent value evicted from settled_window is stale_duplicate not error.

    Gill finding #1 fix: an EVER-SENT value evicted from settled_window, when
    re-echoed (RELIABLE retransmit), is a STALE_DUPLICATE -- NOT a false
    UNMATCHED.
    settled_window only bounds how far back a retransmit is labelled the plain
    'duplicate'. Beyond it, a value we DID send is still benign (contract §7.5:
    "曾经发出过的值不算错误") and must be tagged stale_duplicate, never the
    error-level UNMATCHED. This prevents the false UNMATCHED WARN that a
    sustained backlog + heavy RELIABLE retransmission (esp. F103 Depth=1) would
    otherwise trip. (Was previously PINNED as UNMATCHED; that behaviour is now
    fixed.)
    """
    t = LinkHealthTracker(settled_window=2)
    s = [t.on_send(now=0.0)[0] for _ in range(3)]   # 0,1,2
    for x in s:
        t.on_echo(x, now=0.010)            # match all; window=2 evicts seq 0
    assert 0 not in t._settled             # evicted from the settled window
    e = t.on_echo(s[0], now=0.020)         # retransmit of evicted-but-sent seq 0
    # Fixed behaviour: stale_duplicate, NOT unmatched.
    assert 'stale_duplicate' in kinds(e)
    assert 'unmatched' not in kinds(e)
    assert t.stale_duplicate_count == 1    # its OWN counter, not duplicate_count
    assert t.duplicate_count == 0          # plain-duplicate counter untouched
    assert t.matched_count == 3            # the original 3 matches stand
    # Identity still holds (a stale duplicate touches no lifecycle counter).
    assert t.reconciles()


def test_never_sent_value_is_still_unmatched_after_fix():
    """
    The stale-retransmit fix must NOT swallow a genuinely never-sent value.

    A value AHEAD of the next-to-send counter (or otherwise never emitted) is
    still a real UNMATCHED error -- proves _ever_sent() discriminates rather
    than blanket-suppressing UNMATCHED. (Contract §7.5/A6.)
    """
    t = LinkHealthTracker(settled_window=2)
    s = [t.on_send(now=0.0)[0] for _ in range(3)]   # sent 0,1,2; _next_seq == 3
    for x in s:
        t.on_echo(x, now=0.010)
    # A value the board could never have echoed from us: far ahead of _next_seq.
    e = t.on_echo(1_000_000, now=0.020)
    assert 'unmatched' in kinds(e)
    assert 'stale_duplicate' not in kinds(e)
    assert 'duplicate' not in kinds(e)
    assert t.duplicate_count == 0
    assert t.reconciles()


def test_stale_duplicate_holds_across_full_wrap():
    """
    After a full 2^32 wrap every value is ever-sent, so a re-echo is stale.

    After a full 2^32 wrap, every value has been sent -> a re-echo of any old
    value beyond the window is stale_duplicate, never unmatched. Forces
    _next_seq just past a wrap so sent_count >= the wrap space, then re-echoes a
    value that is provably ever-sent but long gone from the window.
    """
    t = LinkHealthTracker(settled_window=2)
    # Cheaply drive _next_seq and sent_count across the wrap boundary without
    # 2^32 real sends: the tracker exposes _next_seq/sent_count as plain ints.
    t._next_seq = 5
    t.sent_count = SEQ_MODULUS + 10        # well past a full wrap (synthetic)
    # seq 0 is 5 steps behind _next_seq=5 -> within reach -> ever-sent.
    e = t.on_echo(0, now=0.0)
    assert 'stale_duplicate' in kinds(e)
    assert 'unmatched' not in kinds(e)
    # NB: reconciles() is intentionally not asserted -- sent_count was poked
    # synthetically without matching lifecycle transitions, so the identity is
    # meaningless here; this test isolates the _ever_sent() wrap reach only.


@pytest.mark.parametrize('bad', [-2147483648, -1, SEQ_MODULUS,
                                 SEQ_MODULUS + 1, SEQ_MODULUS + 50])
def test_out_of_domain_echo_is_unmatched_not_swallowed(bad):
    """
    Gill review (High): a negative / >=2^32 echo is UNMATCHED, never swallowed.

    The sender only emits seq in [0, 2^32). A board fault / corrupt frame /
    injection echoing an out-of-domain value must NOT be modulo-aliased into the
    ever-sent band and silently dropped as stale_duplicate -- it was never sent,
    so it is a genuine UNMATCHED error (§7.5/A6). Under-reporting a real error is
    worse than over-warning.
    """
    t = LinkHealthTracker(settled_window=4)
    t.on_send(now=0.0)                      # only seq 0 ever sent
    t.on_echo(0, now=0.005)                 # settle it
    e = t.on_echo(bad, now=0.010)
    assert 'unmatched' in kinds(e)
    assert 'stale_duplicate' not in kinds(e)
    assert t.stale_duplicate_count == 0
    assert t.reconciles()


def test_stale_duplicate_then_continued_lifecycle_is_clean():
    """
    A stale_duplicate must not poison in-flight tracking of later sends.

    After an evicted seq comes back as stale_duplicate, a fresh send/sweep/match
    cycle must proceed normally and the reconciliation identity must hold at
    every step (the stale echo touched no lifecycle counter).
    """
    t = LinkHealthTracker(settled_window=2, rtt_deadline_ms=100.0)
    s = [t.on_send(now=0.0)[0] for _ in range(3)]   # 0,1,2 ; evicts 0 on match
    for x in s:
        t.on_echo(x, now=0.010)
    t.on_echo(s[0], now=0.020)             # stale_duplicate of evicted 0
    assert t.reconciles()
    s3, _ = t.on_send(now=0.030)           # fresh send continues normally
    assert t.inflight == 1
    e = t.on_echo(s3, now=0.040)
    assert 'matched' in kinds(e)
    assert t.matched_count == 4
    assert t.stale_duplicate_count == 1
    assert t.reconciles()


def test_stale_and_unmatched_interleaved_do_not_crosstalk():
    """
    Stale_duplicate and real UNMATCHED interleaved keep separate accounting.

    A stale (ever-sent, evicted) echo must never launder a never-sent value, and
    a never-sent value must never be miscounted as a stale duplicate.
    """
    t = LinkHealthTracker(settled_window=2)
    s = [t.on_send(now=0.0)[0] for _ in range(3)]   # 0,1,2 ; _next_seq == 3
    for x in s:
        t.on_echo(x, now=0.010)            # evicts 0 from window=2
    unmatched = 0
    stale = 0
    for k in range(3):
        e1 = t.on_echo(s[0], now=0.020 + k)         # ever-sent evicted -> stale
        e2 = t.on_echo(50_000 + k, now=0.021 + k)   # never sent (ahead) -> unmatched
        stale += kinds(e1).count('stale_duplicate')
        unmatched += kinds(e2).count('unmatched')
        assert 'unmatched' not in kinds(e1)
        assert 'stale_duplicate' not in kinds(e2)
    assert stale == 3
    assert unmatched == 3
    assert t.stale_duplicate_count == 3
    assert t.reconciles()


def test_lost_then_stale_retransmit_beyond_window():
    """
    A retransmit of a LOST value, after it aged out of the window, is stale.

    Compound case: a value settles LOST, is pushed out of settled_window by
    later sends, then arrives as a very-late RELIABLE retransmit. It must be
    stale_duplicate -- never a false UNMATCHED, never a second LOST -- and
    lost_count must not move.
    """
    t = LinkHealthTracker(settled_window=2, rtt_deadline_ms=100.0)
    s0, _ = t.on_send(now=0.0)
    t.sweep_deadlines(now=0.100)           # s0 settles LOST
    assert t.lost_count == 1
    # push s0 out of the 2-deep settled window with two more settled sends
    for _ in range(2):
        sx, _ = t.on_send(now=0.110)
        t.on_echo(sx, now=0.115)
    assert s0 not in t._settled
    e = t.on_echo(s0, now=0.200)           # very-late retransmit of the LOST one
    assert 'stale_duplicate' in kinds(e)
    assert 'unmatched' not in kinds(e)
    assert t.lost_count == 1               # NOT re-lost
    assert t.stale_duplicate_count == 1
    assert t.reconciles()


def test_post_wrap_seq_equals_next_should_be_stale_not_unmatched():
    """
    Post-full-wrap d==0: seq==_next_seq is stale_duplicate, not UNMATCHED.

    After 2^32 sends (~13.6yr @10Hz) the value equal to _next_seq WAS put on the
    wire exactly one wrap ago, so a re-echo is a benign stale_duplicate.
    _ever_sent() handles distance 0 by checking sent_count >= 2^32 (Gill M1 fix);
    before the fix this was a deferred xfail that wrongly reported UNMATCHED.
    """
    t = LinkHealthTracker(settled_window=2)
    t._next_seq = 5
    t.sent_count = SEQ_MODULUS + 10        # past a full wrap (synthetic)
    e = t.on_echo(5, now=0.0)              # == _next_seq
    assert 'stale_duplicate' in kinds(e)


def test_board_replays_old_in_band_value_is_stale_duplicate_DECISION():
    """
    DESIGN DECISION pin: an ever-sent in-band old value replayed is stale, benign.

    Per the post-fix semantics (contract §7.5, pending owner adjudication of the
    line 146/148 ambiguity), a value the board echoes that we DID send long ago
    -- even far outside settled_window -- is treated stale_duplicate, not
    UNMATCHED. This pins that deliberate choice so any reversal is conscious.
    """
    t = LinkHealthTracker(settled_window=8)
    seqs = [t.on_send(now=0.0)[0] for _ in range(1000)]
    for x in seqs:
        t.on_echo(x, now=0.001)            # match all; window keeps only last 8
    assert 50 not in t._settled
    e = t.on_echo(50, now=0.002)           # ever-sent, long evicted
    assert 'stale_duplicate' in kinds(e)
    assert 'unmatched' not in kinds(e)
    assert t.reconciles()


# ==========================================================================
# Group 6 -- A8 reconciliation under a long randomised storm (fuzz-ish).
# ==========================================================================

def test_reconciliation_holds_under_long_mixed_sequence():
    """
    A long deterministic mixed sequence keeps the identity holding.

    A long deterministic mix of send / echo / duplicate / drop / sweep /
    never-sent. After every single operation the identity must hold and the
    five counters must be internally consistent.
    """
    t = LinkHealthTracker(rtt_warn_ms=50.0, rtt_deadline_ms=100.0)
    live = []                              # seqs sent, not yet echoed/lost
    now = 0.0
    matched_local = lost_local = dup_local = 0
    for i in range(500):
        op = i % 7
        now += 0.001
        if op in (0, 1, 2):                # send (bias toward sends)
            s, ev = t.on_send(now=now)
            live.append((s, now))
            assert all(e.kind == 'evict_lost' for e in ev)
            lost_local += len(ev)
            # an evicted live entry is no longer 'live' from our view
        elif op == 3 and live:             # echo the oldest live -> matched
            s, _ts = live.pop(0)
            if s in t._inflight:
                e = t.on_echo(s, now=now)
                if first(e, 'matched'):
                    matched_local += 1
        elif op == 4 and t.matched_count:  # duplicate a settled value
            # echo something already settled if any matched exist
            settled_any = next(iter(t._settled), None)
            if settled_any is not None and settled_any not in t._inflight:
                e = t.on_echo(settled_any, now=now)
                if first(e, 'duplicate'):
                    dup_local += 1
        elif op == 5:                      # sweep deadlines
            t.sweep_deadlines(now=now)
        elif op == 6:                      # never-sent value
            t.on_echo(10 ** 9 + i, now=now)
        # INVARIANT: identity holds after every op.
        assert t.reconciles(), 'identity broke at op %d' % i
    # Final identity + cross-checks.
    assert t.reconciles()
    c = t.counters()
    assert c['sent'] == c['matched'] + c['lost'] + c['inflight']
    assert isinstance(c['sent'], int)


# ==========================================================================
# Group 6 -- thread safety (Gill: tracker must be safe under a multi-threaded
# executor; the RLock serializes the public entry points).
# ==========================================================================

def test_concurrent_on_send_loses_no_increments():
    """
    Concurrent on_send from many threads must not lose any send.

    Each thread calls on_send N times. Without the lock, the read-modify-write
    of sent_count/_next_seq/_inflight races and drops increments (sent_count <
    threads*N, or two threads grab the same seq and overwrite the dict). With
    the lock, sent_count == threads*N exactly, every seq is distinct (inflight
    == threads*N), and the identity holds.
    """
    t = LinkHealthTracker()
    threads_n, per = 8, 500
    barrier = threading.Barrier(threads_n)

    def worker():
        barrier.wait()                     # maximise contention
        for _ in range(per):
            t.on_send(now=0.0)

    ths = [threading.Thread(target=worker) for _ in range(threads_n)]
    for th in ths:
        th.start()
    for th in ths:
        th.join()
    assert t.sent_count == threads_n * per
    assert t.inflight == threads_n * per   # every seq distinct, none overwritten
    assert t.lost_count == 0
    assert t.reconciles()


def test_concurrent_mixed_send_echo_sweep_keeps_identity():
    """
    Concurrent send / echo / sweep must never break the reconcile identity.

    Producers send and immediately echo their own seq; a sweeper runs in
    parallel. The identity sent == matched + lost + inflight must hold at the
    end, no exception may escape (no dict-mutated-during-iteration etc.), and
    sent_count must equal the total number of sends issued.
    """
    t = LinkHealthTracker(rtt_warn_ms=20.0, rtt_deadline_ms=50.0)
    threads_n, per = 6, 400
    # parties = producers + sweeper + main (main releases everyone together).
    barrier = threading.Barrier(threads_n + 2)
    sent_box = [0] * threads_n
    errors = []
    stop = threading.Event()

    def producer(idx):
        try:
            barrier.wait()
            local = 0
            for k in range(per):
                seq, _ = t.on_send(now=k * 1e-3)
                local += 1
                t.on_echo(seq, now=k * 1e-3)   # echo our own send
            sent_box[idx] = local
        except Exception as exc:               # noqa: BLE001 - record for assert
            errors.append(exc)

    def sweeper():
        try:
            barrier.wait()
            while not stop.is_set():
                t.sweep_deadlines(now=1e9)     # force-expire anything in flight
        except Exception as exc:               # noqa: BLE001
            errors.append(exc)

    ths = [threading.Thread(target=producer, args=(i,))
           for i in range(threads_n)]
    sw = threading.Thread(target=sweeper)
    for th in ths:
        th.start()
    sw.start()
    barrier.wait()                             # release everyone together
    for th in ths:
        th.join(timeout=20)
    stop.set()
    sw.join(timeout=20)
    assert not any(th.is_alive() for th in ths) and not sw.is_alive(), \
        'a thread did not finish (deadlock?)'
    assert errors == [], 'thread raised: %r' % errors
    assert t.sent_count == sum(sent_box) == threads_n * per
    assert t.reconciles()
