"""
LinkHealthTracker: rclpy-free link-health logic for the exo round-trip.

Implements the interface contract v1.1 section 7 (link health monitoring,
safety-critical). It is deliberately free of any rclpy / ROS dependency so it
can be unit-tested anywhere (delivering Gill's A1-A7 at the logic layer) and so
the ROS node only has to feed it messages + a monotonic timestamp.

Design contract (see docs/01-ros2-microros-serial/01-接口契约.md §7):

  * §7.1/M1  RTT measured by pairing local t_send[N] with t_recv on echo.
  * §7.2/M2  RTT > rtt_warn_ms -> WARN event (carries seq, rtt_ms, threshold).
  * §7.3/M3  N still un-echoed at t_send[N] + rtt_deadline_ms -> settled LOST,
             lost_count += 1, LOST event. Detected by sweep_deadlines(now).
  * §7.4/M4  in-flight is a deadline-bounded structure. A value leaves in-flight
             ONLY by (1) matched echo or (2) deadline expiry. There is NO
             silent "drop the oldest to cap capacity" path. If a memory cap is
             configured, an evicted entry is still SETTLED AS LOST + warned.
             => the reconciliation identity always holds:
                sent == matched + lost + inflight
  * §7.5/M5  first echo of N -> matched; a later echo of an already-settled N ->
             duplicate_count += 1, DUPLICATE event (NOT unmatched). Only a value
             that was NEVER sent is UNMATCHED.
  * §7.6/P1-3 send counter wraps mod 2^31; ordering uses wrap-safe distance
             (forward_distance), never a bare `>`; in-flight pairing is exact
             equality. Health counters are Python ints (unbounded, >= 64-bit).

The tracker never logs by itself; it returns a list of structured `Event`
objects so the caller (ROS node, or a test) decides how to surface them. This
keeps the class pure and the side effects (logging / diagnostics topic) at the
edge.
"""

from collections import deque
from dataclasses import dataclass, field
from typing import Deque, Dict, List, Optional

# §7.6: heartbeat counter is a non-negative Int32 that wraps mod 2^31.
SEQ_MODULUS = 2 ** 31


def forward_distance(a: int, b: int) -> int:
    """
    Wrap-safe forward distance from a to b in the mod-2^31 sequence space.

    Returns how many steps forward (0 .. 2^31-1) it is from a to b. Used for
    "is b after a, and how far" ordering decisions without a bare `>` that
    would misjudge at the wrap point (§7.6 / P1-3). Equality pairing of
    in-flight entries does NOT use this -- it uses exact `==`, which wrap does
    not affect.
    """
    return (b - a) % SEQ_MODULUS


@dataclass
class Event:
    """
    A structured, level-tagged thing the caller should surface.

    kind is one of: 'matched', 'warn_rtt', 'lost', 'duplicate', 'unmatched',
    'evict_lost'. level is a hint ('DEBUG'/'INFO'/'WARN'/'ERROR') matching the
    severity the contract asks for; the caller maps it to its logger.
    """

    kind: str
    level: str
    seq: int
    msg: str
    rtt_ms: Optional[float] = None
    waited_ms: Optional[float] = None
    threshold_ms: Optional[float] = None


@dataclass
class _InflightEntry:
    seq: int
    t_send: float            # monotonic seconds
    deadline: float          # t_send + rtt_deadline_ms/1000


@dataclass
class LinkHealthTracker:
    """
    Tracks RTT, loss, duplicates and the 5 reconciliation counters.

    Thresholds are injected (the ROS node wires them from params, defaults
    50/200 ms per §7.2). They are NOT hard-coded here beyond the constructor
    defaults, and the constructor enforces rtt_warn_ms < rtt_deadline_ms.

    Time is supplied by the caller as a monotonic clock value in SECONDS
    (e.g. time.monotonic() or a ROS steady-clock value). The tracker never
    reads a clock itself, so tests are deterministic. Wall clock is forbidden
    by the contract (NTP jumps would poison RTT); the tracker simply trusts
    the caller to pass a monotonic value.
    """

    rtt_warn_ms: float = 50.0
    rtt_deadline_ms: float = 200.0
    # Optional memory upper bound on the in-flight structure. None = unbounded
    # (the deadline sweep keeps it bounded in practice). If set and exceeded,
    # the OLDEST-deadline entry is SETTLED AS LOST + warned -- never silently
    # dropped (§7.4 / M4). 0/None disables the cap.
    max_inflight: Optional[int] = None
    # How many most-recently-settled seq values to remember, so a duplicate
    # echo (RELIABLE retransmit, §7.5) is recognised as a DUPLICATE rather than
    # an UNMATCHED error. Bounds memory and gives the contract's "outside a
    # reasonable window" semantics: an echo older than this window is treated
    # as UNMATCHED. Defaults to a generous multiple of the deadline*rate.
    settled_window: int = 4096

    # ----- the five reconciliation counters (Python int, unbounded) ----------
    sent_count: int = 0
    matched_count: int = 0
    lost_count: int = 0
    duplicate_count: int = 0

    # ----- internal state ----------------------------------------------------
    _next_seq: int = 0
    _inflight: Dict[int, _InflightEntry] = field(default_factory=dict)
    # Recently-settled seq values (matched OR lost), bounded to settled_window.
    # Lets us tell "never sent" (UNMATCHED, §7.5/A6) from "already settled"
    # (DUPLICATE, §7.5/A5). A FIFO deque drives eviction order; the set is the
    # O(1) membership index. Both are kept in lockstep.
    _settled: set = field(default_factory=set)
    _settled_order: Deque[int] = field(default_factory=deque)

    def __post_init__(self):
        if not (self.rtt_warn_ms < self.rtt_deadline_ms):
            raise ValueError(
                'rtt_warn_ms (%s) must be < rtt_deadline_ms (%s)'
                % (self.rtt_warn_ms, self.rtt_deadline_ms))
        if self.max_inflight is not None and self.max_inflight <= 0:
            self.max_inflight = None
        if self.settled_window < 1:
            self.settled_window = 1

    def _mark_settled(self, seq: int) -> None:
        """Record seq as settled, evicting the oldest beyond settled_window."""
        if seq in self._settled:
            return
        self._settled.add(seq)
        self._settled_order.append(seq)
        while len(self._settled_order) > self.settled_window:
            old = self._settled_order.popleft()
            self._settled.discard(old)

    def _unmark_settled(self, seq: int) -> None:
        """Forget a settled seq (used when a wrapped seq value is reused)."""
        if seq in self._settled:
            self._settled.discard(seq)
            try:
                self._settled_order.remove(seq)
            except ValueError:
                pass

    # ----- introspection -----------------------------------------------------
    @property
    def inflight(self) -> int:
        """Return the current number of in-flight (sent, not-yet-settled) entries."""
        return len(self._inflight)

    def counters(self) -> dict:
        """Snapshot of the 5 counters; for diagnostics / A8 observability."""
        return {
            'sent': self.sent_count,
            'matched': self.matched_count,
            'lost': self.lost_count,
            'duplicate': self.duplicate_count,
            'inflight': self.inflight,
        }

    def reconciles(self) -> bool:
        """
        Return the A4/A8 reconciliation identity: sent == matched + lost + inflight.

        Duplicate is NOT part of the identity: a duplicate echo does not move a
        value through the sent->{matched,lost} lifecycle (the value was already
        settled), it only increments duplicate_count.
        """
        return self.sent_count == (
            self.matched_count + self.lost_count + self.inflight)

    # ----- send path ---------------------------------------------------------
    def on_send(self, now: float):
        """
        Register a heartbeat being published at monotonic time `now`.

        Returns ``(seq, events)``:
          * ``seq`` is the sequence value to put on the wire. The counter wraps
            mod 2^31 (§7.6).
          * ``events`` is a (usually empty) list of structured events. It is
            non-empty only when a memory cap forced an in-flight entry to be
            SETTLED AS LOST (§7.4 / M4) -- never a silent drop.
        """
        events: List[Event] = []
        seq = self._next_seq
        self._next_seq = (self._next_seq + 1) % SEQ_MODULUS

        deadline = now + self.rtt_deadline_ms / 1000.0
        # Pathological wrap: this seq value is reused while a 2^31-old entry is
        # somehow still in flight. Settle the stale one as LOST so the dict key
        # is never silently overwritten and the identity stays intact.
        if seq in self._inflight:
            stale_events: List[Event] = []
            self._settle_lost(self._inflight[seq], now, kind='evict_lost',
                              level='WARN', reason='seq wrap collision',
                              out=stale_events)
            events.extend(stale_events)
        self._inflight[seq] = _InflightEntry(seq=seq, t_send=now,
                                             deadline=deadline)
        self._unmark_settled(seq)  # in case this seq value was reused (wrap)
        self.sent_count += 1

        # §7.4: enforce a memory cap WITHOUT a silent drop -- the evicted entry
        # is settled as LOST and a warning is emitted.
        if self.max_inflight is not None:
            while len(self._inflight) > self.max_inflight:
                oldest = min(self._inflight.values(), key=lambda e: e.deadline)
                self._settle_lost(oldest, now, kind='evict_lost', level='WARN',
                                  reason='in-flight cap %d exceeded'
                                  % self.max_inflight, out=events)
        return seq, events

    # ----- receive path ------------------------------------------------------
    def on_echo(self, seq: int, now: float) -> List[Event]:
        """
        Process a received mcu_status echo (value=seq) at time `now`.

        Returns the structured events to surface. Exactly one of:
          - matched  (+ optional warn_rtt if RTT over the soft threshold)
          - duplicate (already-settled value seen again -- RELIABLE retransmit)
          - unmatched (a value we have never sent -- a real error, §7.5/A6)
        """
        events: List[Event] = []
        entry = self._inflight.get(seq)
        if entry is not None:
            # First echo of an in-flight value -> matched (§7.1/M1).
            rtt_ms = (now - entry.t_send) * 1000.0
            del self._inflight[seq]
            self._mark_settled(seq)
            self.matched_count += 1
            events.append(Event(
                kind='matched', level='INFO', seq=seq, rtt_ms=rtt_ms,
                msg='matched seq=%d rtt_ms=%.3f' % (seq, rtt_ms)))
            # §7.2/M2 soft-threshold warning.
            if rtt_ms > self.rtt_warn_ms:
                events.append(Event(
                    kind='warn_rtt', level='WARN', seq=seq, rtt_ms=rtt_ms,
                    threshold_ms=self.rtt_warn_ms,
                    msg='RTT over soft threshold: seq=%d rtt_ms=%.3f '
                        'warn_ms=%.1f' % (seq, rtt_ms, self.rtt_warn_ms)))
            return events

        # Not in flight: either already settled (duplicate) or never sent.
        if seq in self._settled:
            # §7.5/M5: duplicate echo of an already-settled value. Normal under
            # RELIABLE retransmit -- NOT an error, must not increment matched.
            self.duplicate_count += 1
            events.append(Event(
                kind='duplicate', level='DEBUG', seq=seq,
                msg='duplicate echo seq=%d (already settled; '
                    'duplicate_count=%d)' % (seq, self.duplicate_count)))
            return events

        # §7.5/A6: a value we have never sent -> genuine UNMATCHED error.
        events.append(Event(
            kind='unmatched', level='WARN', seq=seq,
            msg='UNMATCHED echo seq=%d: never sent (loss/reorder/wrong value)'
                % seq))
        return events

    # ----- deadline sweep ----------------------------------------------------
    def sweep_deadlines(self, now: float) -> List[Event]:
        """
        Settle every in-flight entry whose deadline has passed as LOST.

        Called periodically by the node (a timer, §7.3/M3). Each expired entry
        is removed via the LOST path: lost_count += 1 and a LOST event. This is
        the ONLY capacity-management path besides matched echo -- there is no
        silent eviction (§7.4/M4 / P1-1).
        """
        events: List[Event] = []
        # Collect first to avoid mutating during iteration.
        expired = [e for e in self._inflight.values() if now >= e.deadline]
        for entry in expired:
            self._settle_lost(entry, now, kind='lost', level='ERROR',
                              reason='deadline %.1f ms exceeded'
                              % self.rtt_deadline_ms, out=events)
        return events

    # ----- internal ----------------------------------------------------------
    def _settle_lost(self, entry: _InflightEntry, now: float, kind: str,
                     level: str, reason: str, out: List[Event]) -> None:
        """Move an entry out of in-flight via the LOST path (never silent)."""
        # Guard: only settle if still in flight (avoid double-counting).
        if self._inflight.pop(entry.seq, None) is None:
            return
        self._mark_settled(entry.seq)
        self.lost_count += 1
        waited_ms = (now - entry.t_send) * 1000.0
        out.append(Event(
            kind=kind, level=level, seq=entry.seq, waited_ms=waited_ms,
            threshold_ms=self.rtt_deadline_ms,
            msg='LOST seq=%d: %s (waited_ms=%.3f, deadline_ms=%.1f, '
                'lost_count=%d)' % (entry.seq, reason, waited_ms,
                                    self.rtt_deadline_ms, self.lost_count)))
