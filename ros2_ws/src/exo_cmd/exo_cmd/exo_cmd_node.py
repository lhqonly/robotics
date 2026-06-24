"""
exo_cmd node: WSL-side heartbeat publisher + link-health monitor.

Per the interface contract (v1.7, exo_msgs M-A):
  - publishes /exo/cmd_heartbeat  (exo_msgs/ExoCmd, 10 Hz). header.seq is the
    counter that wraps mod 2^32 (§7.6); header.stamp_mono_ns is the sender's
    monotonic nanoseconds (§7.1); header.crc is the optional application CRC;
    payload is the loopback value, DECOUPLED from header.seq;
  - subscribes /exo/mcu_status    (exo_msgs/ExoStatus) and feeds every echo's
    header.seq (NOT payload) to a LinkHealthTracker that measures RTT, detects
    loss / duplicates / wrap and maintains the reconciliation counters (§7 link
    health, safety-crit);
  - publishes /exo/link_health    (exo_msgs/LinkHealth, ~1 Hz) the structured
    counters + rolling RTT stats + reconcile flag (§7.7).

The actual monitoring logic lives in exo_cmd.link_health.LinkHealthTracker
(rclpy-free, unit-tested). This node is a thin ROS adapter: it owns the
clock, the timers and the publisher/subscriber, and maps the tracker's
structured Events onto the ROS logger.

Clock: we use time.monotonic_ns() for the RTT path (§7.1 forbids wall clock --
NTP jumps would poison RTT). The same monotonic instant feeds the tracker (as
seconds) and header.stamp_mono_ns (as nanoseconds). The LinkHealth message's
std_msgs/Header.stamp uses wall-clock get_clock().now() for the diagnostic /
bag time axis only -- it never enters the RTT path.

Node name: exo_cmd. Topic prefix: /exo/. QoS: see exo_cmd.qos.EXO_QOS.

This node makes no assumption about WHO sends mcu_status: in Phase A it is the
local loopback_node, in Phase B it is the STM32 micro-ROS firmware.
"""

import random
import time

from exo_cmd.crc import compute_crc
from exo_cmd.link_health import LinkHealthTracker
from exo_cmd.qos import EXO_QOS, qos_summary
from exo_msgs.msg import ExoCmd, ExoStatus, LinkHealth
import rclpy
from rclpy.callback_groups import MutuallyExclusiveCallbackGroup
from rclpy.executors import ExternalShutdownException, MultiThreadedExecutor
from rclpy.node import Node

# Contract-defined names (do not change without updating 01-接口契约.md).
TOPIC_HEARTBEAT = '/exo/cmd_heartbeat'
TOPIC_STATUS = '/exo/mcu_status'
TOPIC_LINK_HEALTH = '/exo/link_health'
HEARTBEAT_PERIOD_S = 0.1  # 10 Hz


class ExoCmdNode(Node):
    def __init__(self, **node_kwargs):
        # Forward Node kwargs (e.g. parameter_overrides, context) so tests can
        # inject parameter values at construction time. Production main() passes
        # nothing -> identical behaviour to before.
        super().__init__('exo_cmd', **node_kwargs)

        # ----- params (§7.2: thresholds are runtime-configurable, NOT hard-
        # coded; defaults are the Phase A placeholder values 50/200 ms). -----
        self.declare_parameter('rtt_warn_ms', 50.0)
        self.declare_parameter('rtt_deadline_ms', 200.0)
        # 0 = unbounded in-flight (deadline sweep keeps it bounded). If set,
        # an over-cap entry is settled as LOST + warned, never silently dropped.
        self.declare_parameter('max_inflight', 0)
        # How often the deadline sweep runs (§7.3 loss detection). Should be
        # well below rtt_deadline_ms so loss is reported promptly.
        self.declare_parameter('sweep_period_s', 0.05)
        # Period of the periodic counter/reconciliation summary log (A8). 0 off.
        self.declare_parameter('summary_period_s', 1.0)
        # Period of the /exo/link_health publisher (§7.7, ~1 Hz). Decoupled from
        # summary_period_s. 0 disables the diagnostic topic.
        self.declare_parameter('link_health_period_s', 1.0)
        # Application-level CRC self-check (Q4 / §7.9). Default OFF: cmd.crc is
        # published as 0 and incoming status.crc is NOT checked. When True, the
        # publisher fills header.crc and the subscriber verifies it -- a mismatch
        # increments crc_mismatch_count + WARNs but does NOT block (seq still fed
        # to the tracker). This is a packing-bug self-check, not a link guard.
        self.declare_parameter('crc_enabled', False)
        # How many most-recently-settled seqs to remember before a re-echo is
        # labelled stale_duplicate instead of plain duplicate (§7.5; tunable per
        # Gill's note that it should track deadline*rate*margin). Default matches
        # the tracker's own default; lower it to exercise the stale path.
        self.declare_parameter('settled_window', 4096)
        # Number of executor threads (task ⑤). 0 = let MultiThreadedExecutor
        # pick (os.cpu_count()). main() reads self.executor_threads.
        self.declare_parameter('executor_threads', 0)
        # First heartbeat value (task ③ / §7.6 run nonce). >=0 -> use it as the
        # first value; -1 -> draw a random 32-bit nonce so the echoed values
        # prove THIS run's causality (a board replaying an old 0.. sequence
        # cannot impersonate this run). Default 0 keeps Phase-A determinism.
        self.declare_parameter('start_value', 0)

        rtt_warn_ms = self.get_parameter('rtt_warn_ms').value
        rtt_deadline_ms = self.get_parameter('rtt_deadline_ms').value
        max_inflight = self.get_parameter('max_inflight').value or None
        sweep_period_s = self.get_parameter('sweep_period_s').value
        summary_period_s = self.get_parameter('summary_period_s').value
        link_health_period_s = self.get_parameter('link_health_period_s').value
        settled_window = self.get_parameter('settled_window').value
        self._crc_enabled = bool(self.get_parameter('crc_enabled').value)
        # CRC-mismatch tally (§7.9) lives in the tracker now (Low-3), so the
        # count published on /exo/link_health and the count read here come from
        # ONE source under ONE lock -- no two-copies-can-diverge bug. The node
        # exposes it via the _crc_mismatch_count read-through property below.
        self.executor_threads = self.get_parameter('executor_threads').value
        start_value = self.get_parameter('start_value').value

        # §7.6 run nonce: -1 -> random 32-bit nonce; >=0 -> literal start; any
        # other negative is illegal (turning -1 into a real nonce is the node's
        # job, the tracker only accepts a legal [0, 2^32) start).
        if start_value == -1:
            start_seq = random.randrange(2 ** 32)
        elif start_value >= 0:
            start_seq = start_value
        else:
            self.get_logger().fatal(
                'invalid start_value %d: must be >=0 (literal) or -1 (nonce)'
                % start_value)
            raise ValueError('start_value must be >=0 or -1, got %d'
                             % start_value)

        try:
            self._tracker = LinkHealthTracker(
                rtt_warn_ms=rtt_warn_ms,
                rtt_deadline_ms=rtt_deadline_ms,
                max_inflight=max_inflight,
                settled_window=settled_window,
                start_seq=start_seq,
            )
        except ValueError as exc:
            # §7.2 constraint rtt_warn_ms < rtt_deadline_ms violated: fail loud.
            self.get_logger().fatal('invalid link-health params: %s' % exc)
            raise

        # Callback groups (task ⑤): rx (echo subscription) gets its OWN group so
        # on_status -- which timestamps the safety-critical RTT -- can run
        # CONCURRENTLY with the timers and is NEVER queued behind them under the
        # MultiThreadedExecutor. The three timers share one mutually-exclusive
        # group so they stay serialized w.r.t. each other, preserving the
        # single-threaded-timer semantics the tracker was validated under.
        self._rx_group = MutuallyExclusiveCallbackGroup()    # echo subscription
        self._timer_group = MutuallyExclusiveCallbackGroup()  # the three timers

        self._pub = self.create_publisher(ExoCmd, TOPIC_HEARTBEAT, EXO_QOS)
        self._sub = self.create_subscription(
            ExoStatus, TOPIC_STATUS, self._on_status, EXO_QOS,
            callback_group=self._rx_group)
        # /exo/link_health diagnostic publisher (§7.7). Its own timer (decoupled
        # from summary_period_s) packs counters + RTT stats + reconcile flag.
        self._health_pub = self.create_publisher(
            LinkHealth, TOPIC_LINK_HEALTH, EXO_QOS)
        self._timer = self.create_timer(
            HEARTBEAT_PERIOD_S, self._on_timer,
            callback_group=self._timer_group)
        self._sweep_timer = self.create_timer(
            sweep_period_s, self._on_sweep, callback_group=self._timer_group)
        if summary_period_s and summary_period_s > 0:
            self._summary_timer = self.create_timer(
                summary_period_s, self._on_summary,
                callback_group=self._timer_group)
        if link_health_period_s and link_health_period_s > 0:
            self._health_timer = self.create_timer(
                link_health_period_s, self._on_link_health,
                callback_group=self._timer_group)

        self.get_logger().info(
            'exo_cmd up: pub %s @ %.0f Hz, sub %s'
            % (TOPIC_HEARTBEAT, 1.0 / HEARTBEAT_PERIOD_S, TOPIC_STATUS))
        self.get_logger().info(
            'link-health: rtt_warn_ms=%.1f rtt_deadline_ms=%.1f '
            'max_inflight=%s sweep_period_s=%.3f settled_window=%d'
            % (rtt_warn_ms, rtt_deadline_ms, max_inflight, sweep_period_s,
               settled_window))
        self.get_logger().info(
            'executor_threads=%d (0 = auto / os.cpu_count())'
            % self.executor_threads)
        self.get_logger().info(
            'crc_enabled=%s (application self-check, non-blocking; §7.9), '
            'link_health %s @ %.2f Hz'
            % (self._crc_enabled, TOPIC_LINK_HEALTH,
               (1.0 / link_health_period_s) if link_health_period_s else 0.0))
        # Surface the resolved nonce prominently (§7.6): the echoed values that
        # come back equal to this prove THIS run's causality.
        self.get_logger().info(
            'heartbeat start_seq=%d (run nonce; echoed values prove THIS '
            "run's causality)" % start_seq)
        # Print the LOCAL applied QoS as ground-truth evidence (the CLI shows
        # History/Depth as UNKNOWN for remote endpoints by DDS design).
        self.get_logger().info(
            'applied QoS pub[%s]: %s' % (TOPIC_HEARTBEAT, qos_summary(self._pub)))
        self.get_logger().info(
            'applied QoS sub[%s]: %s' % (TOPIC_STATUS, qos_summary(self._sub)))

    # ----- observables -------------------------------------------------------
    @property
    def _crc_mismatch_count(self) -> int:
        """
        Read-through to the tracker's CRC-mismatch tally (§7.9, single source).

        Kept as a property (not a plain attribute) so the node has no second
        copy that could drift from what /exo/link_health publishes -- both read
        the tracker. Preserves the prior `node._crc_mismatch_count` read API the
        node tests rely on.
        """
        return self._tracker.crc_mismatch_count

    # ----- clock -------------------------------------------------------------
    def _now_ns(self) -> int:
        """Monotonic nanoseconds. §7.1: never wall clock (NTP poisons RTT)."""
        return time.monotonic_ns()

    def _now(self) -> float:
        """Monotonic seconds (for the tracker / sweep / RTT)."""
        return time.monotonic()

    # ----- event surfacing ---------------------------------------------------
    def _emit(self, events) -> None:
        """Map tracker Events onto the ROS logger at their requested level."""
        log = self.get_logger()
        for ev in events:
            level = ev.level
            if level == 'ERROR':
                log.error(ev.msg)
            elif level == 'WARN':
                log.warn(ev.msg)
            elif level == 'DEBUG':
                log.debug(ev.msg)
            else:
                log.info(ev.msg)

    # ----- timers / callbacks ------------------------------------------------
    def _on_timer(self):
        # §7.1: the SAME monotonic instant feeds the tracker (seconds) and the
        # wire stamp (nanoseconds). monotonic_ns() is the single source; the
        # seconds form passed to on_send is derived from it so RTT pairs cleanly.
        now_ns = self._now_ns()
        now_s = now_ns / 1e9
        seq, events = self._tracker.on_send(now_s)
        msg = ExoCmd()
        msg.header.seq = seq
        msg.header.stamp_mono_ns = now_ns
        # payload is the loopback value, DECOUPLED from seq. We reuse seq's value
        # here only as a convenient heartbeat counter; the tracker never reads it
        # (it pairs on header.seq), so it could be anything.
        msg.payload = seq & 0x7FFFFFFF
        msg.header.crc = (compute_crc(seq, now_ns, msg.payload)
                          if self._crc_enabled else 0)
        self._pub.publish(msg)
        self.get_logger().debug('sent cmd_heartbeat seq=%d' % seq)
        # events here are only the (rare) cap-eviction LOST warnings.
        self._emit(events)

    def _on_status(self, msg: ExoStatus):
        # §7.9: when CRC is enabled, verify it BEFORE feeding the tracker, but
        # NEVER block on a mismatch -- a packing bug must stay observable, not
        # silently swallow the seq. seq is taken from header.seq (NOT payload).
        if self._crc_enabled:
            expected = compute_crc(msg.header.seq, msg.header.stamp_mono_ns,
                                   msg.payload)
            if msg.header.crc != expected:
                # §7.9: count via the tracker (single source of truth, taken
                # under its lock so it stays coherent with snapshot()). Read the
                # post-increment value back for the log line.
                self._tracker.note_crc_mismatch()
                self.get_logger().warn(
                    'CRC mismatch seq=%d: got 0x%08X expected 0x%08X '
                    '(application packing self-check; not blocking; '
                    'crc_mismatch_count=%d)'
                    % (msg.header.seq, msg.header.crc, expected,
                       self._tracker.crc_mismatch_count))
        events = self._tracker.on_echo(msg.header.seq, self._now())
        self._emit(events)

    def _on_sweep(self):
        # §7.3/M3: settle every entry past its deadline as LOST.
        events = self._tracker.sweep_deadlines(self._now())
        self._emit(events)

    def _on_summary(self):
        # A8: periodic reconciliation snapshot. Loud if the identity breaks
        # (would indicate a silent-drop bug -- must never happen). One atomic
        # snapshot() (High-1): counters + reconcile flag must come from the SAME
        # instant, or a concurrent rx echo could make the logged line self-
        # contradictory (e.g. reconciles=True printed against stale counters).
        s = self._tracker.snapshot()
        line = ('link-health summary: sent=%d matched=%d lost=%d '
                'duplicate=%d inflight=%d stale_duplicate=%d'
                % (s['sent'], s['matched'], s['lost'], s['duplicate'],
                   s['inflight'], s['stale_duplicate']))
        if s['reconciles']:
            self.get_logger().info(line)
        else:
            self.get_logger().error(
                'RECONCILE BROKEN (sent != matched+lost+inflight): ' + line)

    def _on_link_health(self):
        # §7.7: publish the structured counters + rolling RTT stats + reconcile
        # flag. The std_msgs/Header.stamp is wall-clock (diagnostic / bag time
        # axis only -- NEVER the RTT path, which is monotonic per §7.1).
        #
        # ONE atomic snapshot() (High-1 / Gill review): this topic is the only
        # outward window onto the safety-critical link. Reading counters /
        # rtt_stats / reconciles in three separate lock acquisitions let a
        # concurrent rx echo (MultiThreadedExecutor) mutate the tracker between
        # them, so a single LinkHealth msg could carry fields from different
        # instants -- a torn snapshot that masks loss. snapshot() reads them all
        # under one lock.
        s = self._tracker.snapshot()
        msg = LinkHealth()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.sent = s['sent']
        msg.matched = s['matched']
        msg.lost = s['lost']
        msg.duplicate = s['duplicate']
        msg.stale_duplicate = s['stale_duplicate']
        # §7.9 side-channel observable: from the SAME snapshot() as the rest, so
        # it is never from a different instant (no torn message). 0 when
        # crc_enabled=False (the tracker is never told to note a mismatch).
        msg.crc_mismatch = s['crc_mismatch']
        msg.inflight = s['inflight']
        msg.rtt_last_ms = s['rtt_last_ms']
        msg.rtt_p95_ms = s['rtt_p95_ms']
        msg.rtt_max_ms = s['rtt_max_ms']
        msg.reconciles = s['reconciles']
        self._health_pub.publish(msg)


def main(args=None):
    rclpy.init(args=args)
    node = ExoCmdNode()
    # task ⑤: run under a MultiThreadedExecutor so the rx group (echo / RTT
    # timestamping) can execute concurrently with the timer group. 0 -> None
    # lets the executor pick os.cpu_count(). Catching ExternalShutdownException
    # also gives a clean exit on SIGTERM (systemd stop) -- no traceback.
    threads = node.executor_threads or None
    executor = MultiThreadedExecutor(num_threads=threads)
    executor.add_node(node)
    try:
        executor.spin()
    except (KeyboardInterrupt, ExternalShutdownException):
        pass
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == '__main__':
    main()
