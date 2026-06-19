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
  * §7.6/P1-3 wrap mod 2^31: behaviour AT the boundary, forced full-wrap seq
    collision while an old entry is still in flight;
  * §7.5/P1-2 duplicate/retransmit: an already-settled value re-echoed must be
    duplicate, never UNMATCHED/wrong-value;
  * param validation rtt_warn_ms < rtt_deadline_ms (equal / reversed rejected);
  * settled_window boundary: a retransmit older than the remembered window is
    (per contract) treated UNMATCHED -- pinned here so the behaviour is a
    DOCUMENTED, intentional choice rather than a silent surprise.

Every test asserts reconciles() so a silent-drop regression cannot slip by.
"""

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
# Group 3 -- §7.6 / P1-3 WRAP at the 2^31 boundary.
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
    s0, _ = t.on_send(now=0.0)             # 2^31-2
    s1, _ = t.on_send(now=0.0)             # 2^31-1
    s2, _ = t.on_send(now=0.0)             # wraps to 0
    assert s0 == SEQ_MODULUS - 2
    assert s1 == SEQ_MODULUS - 1
    assert s2 == 0
    assert all(0 <= s < SEQ_MODULUS for s in (s0, s1, s2))
    assert t._next_seq == 1


def test_forced_full_wrap_seq_collision_settles_stale_as_lost():
    """
    A full 2^31 wrap onto a still-in-flight seq settles the stale entry LOST.

    Pathological: a full 2^31 wrap lands on a seq whose OLD entry is still
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
    a, _ = t.on_send(now=0.0)              # 2^31-2  -> will be matched
    b, _ = t.on_send(now=0.0)              # 2^31-1  -> will be lost
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
# Group 5 -- settled_window boundary (DOCUMENTED behaviour pin).
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


def test_retransmit_older_than_window_becomes_unmatched_DOCUMENTED():
    """
    ADVERSARIAL FINDING (documented, not a hard failure).

    settled_window bounds how far back a retransmit is still recognised as a
    duplicate. A RELIABLE retransmit for a value that was settled but has since
    been evicted from the settled window is reported UNMATCHED (a WARN that the
    node surfaces as a real error), NOT duplicate.

    The contract §7.5 explicitly allows: 'a value ... already outside a
    reasonable window ... is UNMATCHED'. So this is permitted. BUT the default
    window is 4096; under a sustained backlog + heavy RELIABLE retransmission,
    a genuinely-late retransmit could trip a false UNMATCHED WARN. This test
    PINS the behaviour so any future change is deliberate; see Gill's report
    for the recommendation (raise/justify the default, or distinguish
    'stale-retransmit' from 'never-sent').
    """
    t = LinkHealthTracker(settled_window=2)
    s = [t.on_send(now=0.0)[0] for _ in range(3)]   # 0,1,2
    for x in s:
        t.on_echo(x, now=0.010)            # match all; window=2 evicts seq 0
    assert 0 not in t._settled             # evicted from the settled window
    e = t.on_echo(s[0], now=0.020)         # retransmit of evicted seq 0
    # Current shipping behaviour: reported UNMATCHED, NOT duplicate.
    assert 'unmatched' in kinds(e)
    assert 'duplicate' not in kinds(e)
    assert t.duplicate_count == 0
    # Identity still holds (an unmatched echo touches no lifecycle counter).
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
