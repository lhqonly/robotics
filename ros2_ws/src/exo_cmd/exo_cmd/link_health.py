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
             duplicate_count += 1, DUPLICATE event (NOT unmatched). A retransmit
             of an EVER-SENT value whose settled record already aged out of
             settled_window -> stale_duplicate_count += 1, STALE_DUPLICATE event
             (still NOT unmatched, per "曾经发出过的值不算错误"; Gill finding #1) --
             a SEPARATE counter so its rate stays a visible link-quality signal.
             Only a value that was NEVER sent -- including any echo outside the
             [0,2^32) send domain -- is UNMATCHED.
  * §7.6/P1-3 send counter wraps mod 2^32; ordering uses wrap-safe distance
             (forward_distance), never a bare `>`; in-flight pairing is exact
             equality. Health counters are Python ints (unbounded, >= 64-bit).

The tracker also keeps a bounded rolling RTT window (deque, exo_msgs M-A / §7.7)
so the node can publish rtt_last_ms / rtt_p95_ms / rtt_max_ms on
/exo/link_health alongside the reconciliation counters.

The tracker never logs by itself; it returns a list of structured `Event`
objects so the caller (ROS node, or a test) decides how to surface them. This
keeps the class pure and the side effects (logging / diagnostics topic) at the
edge.
"""

from collections import deque
from dataclasses import dataclass, field
import heapq
import math
import threading
from typing import Deque, Dict, List, Optional, Tuple

# §7.6 / exo_msgs M-A: seq is the wire field ExoHeader.seq (uint32) that wraps
# mod 2^32. (Was mod 2^31 under the std_msgs/Int32 baseline; the explicit
# uint32 field doubles the range and removes the signed-Int32 constraint.)
SEQ_MODULUS = 2 ** 32

# Default size of the bounded rolling RTT window (exo_msgs M-A / §7.7). At
# 10 Hz this is ~100 s of history; generous enough for a stable p95 without
# unbounded memory. Configurable via LinkHealthTracker.rtt_window.
DEFAULT_RTT_WINDOW = 1024

# Deterministic placeholder for RTT stats when the window is empty: no matched
# echo has been observed yet, so there is no RTT to report. 0.0 (not nan) keeps
# the published LinkHealth fields plain floats and the tests' expectations
# written down explicitly.
RTT_EMPTY_PLACEHOLDER = 0.0


def forward_distance(a: int, b: int) -> int:
    """
    Wrap-safe forward distance from a to b in the mod-2^32 sequence space.

    Returns how many steps forward (0 .. 2^32-1) it is from a to b. Used for
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

    kind is one of: 'matched', 'warn_rtt', 'lost', 'duplicate',
    'stale_duplicate', 'unmatched', 'evict_lost'. level is a hint
    ('DEBUG'/'INFO'/'WARN'/'ERROR') matching the severity the contract asks
    for; the caller maps it to its logger.
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
    # an UNMATCHED error. Bounds memory. An echo for an EVER-SENT value older
    # than this window is NOT unmatched -- it is a STALE_DUPLICATE (Gill finding
    # #1): only a NEVER-SENT value is UNMATCHED. The window therefore only
    # decides duplicate vs stale_duplicate labelling, never duplicate-vs-error.
    # Defaults to a generous multiple of the deadline*rate.
    settled_window: int = 4096
    # Initial value of the send counter (§7.6, wraps mod 2^32). Lets each run
    # start at a random 32-bit nonce so the echoed values prove THIS run's
    # causality; default 0 keeps Phase-A determinism. Turning the -1 sentinel
    # into a real nonce is the NODE's job; the tracker only accepts a legal
    # [0, 2^32) start.
    start_seq: int = 0
    # Size of the bounded rolling RTT window (exo_msgs M-A / §7.7). Each matched
    # echo pushes its rtt_ms; the oldest is evicted once the window is full, so
    # memory stays bounded. p95/max are computed over this window; rtt_last_ms
    # is the most recent matched RTT (independent of the window contents).
    rtt_window: int = DEFAULT_RTT_WINDOW

    # ----- the reconciliation counters (Python int, unbounded) ---------------
    sent_count: int = 0
    matched_count: int = 0
    lost_count: int = 0
    duplicate_count: int = 0
    # In-window duplicate (above) vs. ever-sent retransmit that already aged out
    # of settled_window are counted SEPARATELY (Gill review): a rising
    # stale_duplicate rate is a distinct link-quality signal -- it means
    # settled_window is undersized / the link is backlogged, NOT ordinary DDS
    # retransmit. Folding them together would mute that signal.
    stale_duplicate_count: int = 0
    # Application-level CRC self-check mismatches (§7.9). NOT a reconciliation
    # counter: a CRC mismatch is non-blocking (the seq still flows through the
    # sent->{matched,lost} lifecycle), so this is a SIDE-CHANNEL observable only
    # and MUST NOT enter the reconcile identity. It lives in the tracker (not the
    # node) so snapshot() returns it under the SAME lock as sent/matched/rtt --
    # i.e. /exo/link_health never publishes a crc_mismatch from a different
    # instant than the rest of the message (no torn snapshot; High-1 invariant).
    crc_mismatch_count: int = 0

    # ----- internal state ----------------------------------------------------
    _next_seq: int = 0
    _inflight: Dict[int, _InflightEntry] = field(default_factory=dict)
    # Min-heap of (deadline, seq) over the in-flight entries, used ONLY by the
    # §7.4 cap-eviction path to find the OLDEST-deadline victim in O(log N)
    # instead of an O(N) min() scan under the lock (Med-3: the scan held _lock
    # for O(N) on every over-cap send, lengthening lock occupancy and delaying
    # safety telemetry when the link is backlogged + the cap is saturated).
    #
    # Consistency model (heap <-> _inflight), all maintained INSIDE _lock:
    #   * The heap is a SUPERSET of the live in-flight entries. matched (on_echo)
    #     and lost (_settle_lost) removals do NOT eagerly remove from the heap --
    #     they only delete from _inflight. So the heap accumulates STALE tuples
    #     whose seq is no longer in _inflight, or whose deadline no longer matches
    #     the current entry for that seq (a seq reused after a 2^32 wrap gets a new
    #     deadline => the old tuple is stale).
    #   * LAZY DELETION at pick time: _pop_oldest_inflight() pops the heap until
    #     the top tuple is VALIDATED against _inflight (seq present AND deadline
    #     equal). Stale tuples are discarded. This guarantees the chosen victim is
    #     a genuinely live, oldest-deadline entry -- never an already-settled one
    #     (no KeyError, no mis-picked victim).
    #   * The heap is ONLY maintained when a cap is configured (max_inflight set);
    #     with no cap (the default) nothing pushes to it, so that path is byte-for
    #     -byte unchanged and pays zero heap cost. __post_init__ sizes it lazily.
    # Excluded from compare/repr: it is derived state, not value identity.
    _inflight_heap: List[Tuple[float, int]] = field(
        default_factory=list, compare=False, repr=False)
    # Recently-settled seq values (matched OR lost), bounded to settled_window.
    # Lets us tell "never sent" (UNMATCHED, §7.5/A6) from "already settled"
    # (DUPLICATE, §7.5/A5). A FIFO deque drives eviction order; the set is the
    # O(1) membership index. Both are kept in lockstep.
    _settled: set = field(default_factory=set)
    _settled_order: Deque[int] = field(default_factory=deque)
    # Bounded rolling RTT window (exo_msgs M-A / §7.7). maxlen is set in
    # __post_init__ from rtt_window so the deque self-evicts the oldest sample.
    # _rtt_last holds the most recent matched RTT even after it ages out of the
    # window (so rtt_last_ms is always the truly-latest matched echo).
    _rtt_window: Deque[float] = field(default_factory=deque)
    _rtt_last: Optional[float] = None
    # Serializes the public mutating/reading entry points so a multi-threaded
    # rclpy executor (sub callback on one thread, sweep/summary timers on others)
    # cannot interleave a counter update with a snapshot or corrupt _inflight /
    # _settled. REENTRANT so a locked reader (counters()) can call another locked
    # reader (inflight) without deadlock. Single-threaded callers pay a tiny
    # uncontended-lock cost. (Gill: tracker was not thread-safe; safe only under
    # a single-threaded executor until now.) compare/repr excluded: a lock is not
    # part of the value identity.
    _lock: threading.RLock = field(
        default_factory=threading.RLock, compare=False, repr=False)

    def __post_init__(self):
        if not (self.rtt_warn_ms < self.rtt_deadline_ms):
            raise ValueError(
                'rtt_warn_ms (%s) must be < rtt_deadline_ms (%s)'
                % (self.rtt_warn_ms, self.rtt_deadline_ms))
        if self.max_inflight is not None and self.max_inflight <= 0:
            self.max_inflight = None
        if self.settled_window < 1:
            self.settled_window = 1
        if not (0 <= self.start_seq < SEQ_MODULUS):
            # Upper bound guarded too (Gill L1): a >=2^32 start would silently
            # alias through the % below, undermining the run-nonce auditability.
            raise ValueError(
                'start_seq (%s) must be in [0, 2^32)' % self.start_seq)
        if self.rtt_window < 1:
            self.rtt_window = 1
        # Bind the deque's maxlen so it self-evicts the oldest RTT sample.
        self._rtt_window = deque(maxlen=self.rtt_window)
        self._next_seq = self.start_seq % SEQ_MODULUS
        # A non-zero origin stays correct: _ever_sent / forward_distance work off
        # forward_distance(seq, _next_seq) and sent_count, both relative to the
        # moving _next_seq -- they never depend on the absolute origin being 0.

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

    # ----- side-channel observables ------------------------------------------
    def note_crc_mismatch(self) -> None:
        """
        Record one application-level CRC self-check mismatch (§7.9).

        Public mutating entry point, taken under self._lock like every other
        public entry, so the increment is consistent with a concurrent
        snapshot()/counters() read under the MultiThreadedExecutor. This is the
        SINGLE source of truth for the CRC-mismatch tally (the node no longer
        keeps its own copy) so the count published on /exo/link_health and the
        count the node logs cannot diverge. NON-BLOCKING by contract: callers
        still feed the echo's seq to on_echo() after noting the mismatch -- the
        count is an observable signal, never a reason to drop a seq, and it never
        enters the reconcile identity.
        """
        with self._lock:
            self.crc_mismatch_count += 1

    # ----- introspection -----------------------------------------------------
    @property
    def inflight(self) -> int:
        """Return the current number of in-flight (sent, not-yet-settled) entries."""
        with self._lock:
            return len(self._inflight)

    def counters(self) -> dict:
        """Snapshot of the counters; for diagnostics / A8 observability."""
        with self._lock:
            return self._counters_locked()

    def _counters_locked(self) -> dict:
        """Lock-held body of counters() (caller must hold self._lock)."""
        return {
            'sent': self.sent_count,
            'matched': self.matched_count,
            'lost': self.lost_count,
            'duplicate': self.duplicate_count,
            'stale_duplicate': self.stale_duplicate_count,
            # Side-channel observable (§7.9): reported alongside the reconcile
            # counters but deliberately NOT part of the identity (see
            # reconciles()/_reconciles_locked -- it stays out of the sum).
            'crc_mismatch': self.crc_mismatch_count,
            'inflight': len(self._inflight),
        }

    def rtt_stats(self) -> dict:
        """
        Snapshot of the rolling-window RTT stats (exo_msgs M-A / §7.7).

        Returns a dict with:
          * ``rtt_last_ms`` -- the most recent matched RTT (independent of the
            window; survives a sample ageing out of the window);
          * ``rtt_p95_ms`` -- the 95th percentile over the current window;
          * ``rtt_max_ms`` -- the maximum over the current window.

        When no matched echo has been seen yet (empty window), all three are the
        deterministic placeholder ``RTT_EMPTY_PLACEHOLDER`` (0.0) so the
        published LinkHealth fields stay plain floats and the expected values are
        written down explicitly in the tests.

        p95 uses the nearest-rank method on the sorted window
        (``ceil(0.95 * n)``-th sample, 1-indexed): deterministic, no
        interpolation, no numpy dependency.
        """
        with self._lock:
            return self._rtt_stats_locked()

    def _rtt_stats_locked(self) -> dict:
        """Lock-held body of rtt_stats() (caller must hold self._lock)."""
        if not self._rtt_window:
            return {
                'rtt_last_ms': RTT_EMPTY_PLACEHOLDER,
                'rtt_p95_ms': RTT_EMPTY_PLACEHOLDER,
                'rtt_max_ms': RTT_EMPTY_PLACEHOLDER,
            }
        ordered = sorted(self._rtt_window)
        n = len(ordered)
        # Nearest-rank p95: 1-indexed ceil(0.95*n), clamped into range.
        rank = max(1, min(n, math.ceil(0.95 * n)))
        last = self._rtt_last
        return {
            'rtt_last_ms': (RTT_EMPTY_PLACEHOLDER if last is None
                            else last),
            'rtt_p95_ms': ordered[rank - 1],
            'rtt_max_ms': ordered[-1],
        }

    def reconciles(self) -> bool:
        """
        Return the A4/A8 reconciliation identity: sent == matched + lost + inflight.

        Duplicate is NOT part of the identity: a duplicate echo does not move a
        value through the sent->{matched,lost} lifecycle (the value was already
        settled), it only increments duplicate_count.
        """
        with self._lock:
            return self._reconciles_locked()

    def _reconciles_locked(self) -> bool:
        """Lock-held body of reconciles() (caller must hold self._lock)."""
        return self.sent_count == (
            self.matched_count + self.lost_count + len(self._inflight))

    def snapshot(self) -> dict:
        """
        Return a coherent atomic snapshot read under ONE lock (High-1 / Gill).

        Counters + RTT stats + reconcile flag are read under a single lock
        acquisition.

        Why: /exo/link_health is the only outward-observable window onto the
        safety-critical link. If the node read counters(), rtt_stats() and
        reconciles() in three separate lock acquisitions, an rx echo callback
        (running concurrently under the MultiThreadedExecutor) could mutate the
        tracker BETWEEN those reads, so a single published LinkHealth message
        could carry fields from different instants -- a self-contradictory
        snapshot that would mask loss (e.g. matched bumped after sent was read).
        Taking everything inside one `with self._lock` makes the message a
        torn-free, single-instant view.

        The returned dict flattens the three sub-dicts so the node packs the
        LinkHealth message from one object. Field names/semantics are IDENTICAL
        to counters() / rtt_stats() / reconciles() (contract §7.7), so callers
        and tests need no remapping. Internal *_locked helpers are reused so
        there is exactly one definition of each computation.
        """
        with self._lock:
            c = self._counters_locked()
            r = self._rtt_stats_locked()
            return {
                'sent': c['sent'],
                'matched': c['matched'],
                'lost': c['lost'],
                'duplicate': c['duplicate'],
                'stale_duplicate': c['stale_duplicate'],
                'crc_mismatch': c['crc_mismatch'],
                'inflight': c['inflight'],
                'rtt_last_ms': r['rtt_last_ms'],
                'rtt_p95_ms': r['rtt_p95_ms'],
                'rtt_max_ms': r['rtt_max_ms'],
                'reconciles': self._reconciles_locked(),
            }

    # ----- send path ---------------------------------------------------------
    def on_send(self, now: float):
        """
        Register a heartbeat being published at monotonic time `now`.

        Returns ``(seq, events)``:
          * ``seq`` is the sequence value to put on the wire. The counter wraps
            mod 2^32 (§7.6).
          * ``events`` is a (usually empty) list of structured events. It is
            non-empty only when a memory cap forced an in-flight entry to be
            SETTLED AS LOST (§7.4 / M4) -- never a silent drop.
        """
        with self._lock:
            events: List[Event] = []
            seq = self._next_seq
            self._next_seq = (self._next_seq + 1) % SEQ_MODULUS

            deadline = now + self.rtt_deadline_ms / 1000.0
            # Pathological wrap: this seq value is reused while a 2^32-old entry
            # is somehow still in flight. Settle the stale one as LOST so the
            # dict key is never silently overwritten and the identity stays
            # intact.
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

            # §7.4: enforce a memory cap WITHOUT a silent drop -- the evicted
            # entry is settled as LOST and a warning is emitted. The cap path
            # uses the deadline min-heap (O(log N)); the no-cap path never
            # touches the heap, so its behaviour is unchanged.
            if self.max_inflight is not None:
                # Track the new entry in the heap so it can be a future victim.
                # (deadline, seq) ties break on seq -- harmless; both are 'oldest'.
                heapq.heappush(self._inflight_heap, (deadline, seq))
                # Opportunistic compaction: matched/lost removals leave stale
                # tuples behind (lazy deletion), so the heap can grow past the
                # live count even when the cap is rarely hit. When stale tuples
                # outnumber live entries (heap > 2x live), rebuild the heap from
                # the live entries only -- O(N) but amortised rare, keeping the
                # heap O(live) so memory and pops stay bounded. Bounded by the cap
                # anyway via the eviction below, but this also covers the
                # cap-set-but-not-yet-hit churn (sends matched/lost faster than
                # the cap is reached).
                if len(self._inflight_heap) > 2 * len(self._inflight) + 8:
                    self._inflight_heap = [
                        (e.deadline, e.seq) for e in self._inflight.values()]
                    heapq.heapify(self._inflight_heap)
                while len(self._inflight) > self.max_inflight:
                    oldest = self._pop_oldest_inflight()
                    # oldest cannot be None here: len(_inflight) > cap >= 1, and
                    # every live entry has a heap tuple, so a live victim exists.
                    self._settle_lost(oldest, now, kind='evict_lost',
                                      level='WARN',
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
          - stale_duplicate (ever-sent value re-echoed but aged out of the
            settled window -- still a benign retransmit, NOT an error; §7.5,
            Gill finding #1; counted in stale_duplicate_count)
          - unmatched (a value we have NEVER sent, INCLUDING any echo outside the
            [0,2^32) send domain -- a real error, §7.5/A6)
        """
        with self._lock:
            return self._on_echo_locked(seq, now)

    def _on_echo_locked(self, seq: int, now: float) -> List[Event]:
        """Lock-held body of on_echo (caller must hold self._lock)."""
        events: List[Event] = []
        # Domain guard (Gill review, High): the sender only ever emits seq in
        # [0, 2^32). A negative or >= 2^32 echo cannot have come from us -> it
        # was NEVER sent (board fault / corrupt frame / injection). Classify it
        # UNMATCHED here, BEFORE _ever_sent() could modulo-alias an out-of-domain
        # value into the ever-sent band and silently swallow it as a stale
        # duplicate. Under-reporting a real UNMATCHED is worse than over-warning.
        if not (0 <= seq < SEQ_MODULUS):
            events.append(Event(
                kind='unmatched', level='WARN', seq=seq,
                msg='UNMATCHED echo seq=%d: outside [0,2^32) -- never sent '
                    '(board fault / corrupt frame)' % seq))
            return events
        entry = self._inflight.get(seq)
        if entry is not None:
            # First echo of an in-flight value -> matched (§7.1/M1).
            rtt_ms = (now - entry.t_send) * 1000.0
            del self._inflight[seq]
            self._mark_settled(seq)
            self.matched_count += 1
            # exo_msgs M-A / §7.7: feed the bounded rolling RTT window so the
            # node can publish rtt_last/p95/max on /exo/link_health. The deque's
            # maxlen evicts the oldest sample; _rtt_last keeps the truly-latest
            # matched RTT even after it ages out of the window.
            self._rtt_window.append(rtt_ms)
            self._rtt_last = rtt_ms
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

        # Not in the remembered settled window. Distinguish a value we DID send
        # but whose settled record already aged out of settled_window (a stale
        # RELIABLE retransmit -- benign, contract §7.5 "曾经发出过的值不算错误")
        # from a value we have genuinely NEVER sent (a real UNMATCHED error).
        # This is Gill finding #1: without this split, a late retransmit under a
        # sustained backlog (esp. F103 Depth=1) trips a FALSE UNMATCHED WARN.
        if self._ever_sent(seq):
            # Ever-sent but beyond settled_window. NOT part of the reconcile
            # identity (the value already settled), and counted in its OWN
            # counter (Gill review) so an elevated rate stays a visible
            # link-quality signal -- a high stale_duplicate rate means
            # settled_window is undersized / the link is backlogged, NOT a board
            # fault. INFO (not DEBUG) so a single occurrence is not muted.
            self.stale_duplicate_count += 1
            events.append(Event(
                kind='stale_duplicate', level='INFO', seq=seq,
                msg='stale duplicate echo seq=%d: ever-sent but beyond '
                    'settled_window=%d (RELIABLE retransmit, not an error; '
                    'stale_duplicate_count=%d)'
                    % (seq, self.settled_window, self.stale_duplicate_count)))
            return events

        # §7.5/A6: a value we have NEVER sent -> genuine UNMATCHED error.
        events.append(Event(
            kind='unmatched', level='WARN', seq=seq,
            msg='UNMATCHED echo seq=%d: never sent (loss/reorder/wrong value)'
                % seq))
        return events

    def _ever_sent(self, seq: int) -> bool:
        """
        Return whether `seq` was ever put on the wire (wrap-safe).

        Sent values occupy the band [1 .. reach] steps BEHIND the next-to-send
        value ``_next_seq`` -- ``forward_distance(seq, _next_seq)`` counts steps
        from ``seq`` forward to ``_next_seq``. Distance 0 means ``seq`` IS the
        next, not-yet-sent value; distance > reach means ``seq`` is a value we
        have not reached yet (ahead of us) -> never sent. ``reach`` is how many
        distinct values we have ever emitted, capped at the wrap-space size
        (after a full 2^32 wrap every value has been sent at least once).
        """
        d = forward_distance(seq, self._next_seq)
        if d == 0:
            # d==0 means seq IS _next_seq (the not-yet-sent value) -- UNLESS we
            # have already cycled a full 2^32, in which case this exact value
            # was put on the wire exactly one wrap ago and IS ever-sent (a stale
            # duplicate, not a never-sent UNMATCHED). Gill M1.
            return self.sent_count >= SEQ_MODULUS
        return d <= min(self.sent_count, SEQ_MODULUS - 1)

    # ----- deadline sweep ----------------------------------------------------
    def sweep_deadlines(self, now: float) -> List[Event]:
        """
        Settle every in-flight entry whose deadline has passed as LOST.

        Called periodically by the node (a timer, §7.3/M3). Each expired entry
        is removed via the LOST path: lost_count += 1 and a LOST event. This is
        the ONLY capacity-management path besides matched echo -- there is no
        silent eviction (§7.4/M4 / P1-1).
        """
        with self._lock:
            events: List[Event] = []
            # Collect first to avoid mutating during iteration.
            expired = [e for e in self._inflight.values()
                       if now >= e.deadline]
            for entry in expired:
                self._settle_lost(entry, now, kind='lost', level='ERROR',
                                  reason='deadline %.1f ms exceeded'
                                  % self.rtt_deadline_ms, out=events)
            return events

    # ----- internal ----------------------------------------------------------
    def _pop_oldest_inflight(self) -> Optional[_InflightEntry]:
        """
        Return the live in-flight entry with the smallest deadline (O(log N)).

        Caller must hold self._lock. Pops the (deadline, seq) min-heap, applying
        LAZY DELETION: a popped tuple is only accepted if it still matches a live
        _inflight entry -- the seq must be present AND its deadline must equal the
        tuple's deadline. A tuple fails this check when:
          * the entry was already settled (matched echo / LOST) -- its dict key is
            gone, so the tuple is stale; or
          * the seq was reused after a 2^32 wrap -- the live entry now carries a
            DIFFERENT (newer) deadline, so the OLD tuple is stale and must not be
            allowed to mis-target the fresh entry.
        Stale tuples are discarded (they are pure garbage at this point). This is
        why on_echo / _settle_lost need not touch the heap: their removals simply
        leave tuples that this routine skips. Returns None only if the heap holds
        no live entry (should not happen when len(_inflight) > 0, but handled
        defensively rather than raising).

        The popped victim's tuple is consumed here; _settle_lost then removes it
        from _inflight, so no further heap bookkeeping is needed for the victim.

        CORRECTNESS DEPENDENCY (do not break in refactors): the deadline-equality
        check distinguishes a stale tuple from a live one ONLY when their deadlines
        differ. A wrap-reused seq could in principle land on the SAME deadline as
        the old tuple (clock granularity collision); then `entry.deadline ==
        deadline` cannot tell old from new. Safety does NOT rely on that check in
        the collision case -- it relies on the invariant that the OLD entry has
        ALREADY left _inflight before the new same-seq entry is admitted: a seq is
        only re-armed after its prior occupant was settled (matched echo or
        _settle_lost popped it from _inflight). So at any instant _inflight holds
        at most one entry per seq, and `.get(seq)` returns the live (new) entry;
        the old tuple, when later popped, finds either no seq (already settled) or
        a newer entry whose deadline differs -> discarded. The deadline check is
        thus a fast-path filter for the common stale case, not the load-bearing
        guard for wrap collisions. If a future change ever allows two live entries
        with the same seq to coexist in _inflight, this routine becomes unsound.
        """
        while self._inflight_heap:
            deadline, seq = heapq.heappop(self._inflight_heap)
            entry = self._inflight.get(seq)
            if entry is not None and entry.deadline == deadline:
                return entry
            # else: stale tuple (settled, or superseded by a wrap-reused seq) ->
            # discard and keep popping.
        return None

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
