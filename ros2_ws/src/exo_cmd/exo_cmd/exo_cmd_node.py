"""
exo_cmd node: WSL-side heartbeat publisher + link-health monitor.

Per the interface contract (v1.1):
  - publishes /exo/cmd_heartbeat  (std_msgs/Int32, 10 Hz, data = counter that
    wraps mod 2^31, starting at 0, +1 each tick -- §7.6);
  - subscribes /exo/mcu_status    (std_msgs/Int32) and feeds every echo to a
    LinkHealthTracker that measures RTT, detects loss / duplicates / wrap and
    maintains the five reconciliation counters (§7 link health, safety-crit).

The actual monitoring logic lives in exo_cmd.link_health.LinkHealthTracker
(rclpy-free, unit-tested). This node is a thin ROS adapter: it owns the
clock, the timers and the publisher/subscriber, and maps the tracker's
structured Events onto the ROS logger.

Clock: we use time.monotonic() (§7.1 forbids wall clock -- NTP jumps would
poison RTT). The tracker never reads a clock itself; we pass it in.

Node name: exo_cmd. Topic prefix: /exo/. QoS: see exo_cmd.qos.EXO_QOS.

This node makes no assumption about WHO sends mcu_status: in Phase A it is the
local loopback_node, in Phase B it is the STM32 micro-ROS firmware.
"""

import random
import time

from exo_cmd.link_health import LinkHealthTracker
from exo_cmd.qos import EXO_QOS, qos_summary
import rclpy
from rclpy.callback_groups import MutuallyExclusiveCallbackGroup
from rclpy.executors import ExternalShutdownException, MultiThreadedExecutor
from rclpy.node import Node
from std_msgs.msg import Int32

# Contract-defined names (do not change without updating 01-接口契约.md).
TOPIC_HEARTBEAT = '/exo/cmd_heartbeat'
TOPIC_STATUS = '/exo/mcu_status'
HEARTBEAT_PERIOD_S = 0.1  # 10 Hz


class ExoCmdNode(Node):
    def __init__(self):
        super().__init__('exo_cmd')

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
        # How many most-recently-settled seqs to remember before a re-echo is
        # labelled stale_duplicate instead of plain duplicate (§7.5; tunable per
        # Gill's note that it should track deadline*rate*margin). Default matches
        # the tracker's own default; lower it to exercise the stale path.
        self.declare_parameter('settled_window', 4096)
        # Number of executor threads (task ⑤). 0 = let MultiThreadedExecutor
        # pick (os.cpu_count()). main() reads self.executor_threads.
        self.declare_parameter('executor_threads', 0)
        # First heartbeat value (task ③ / §7.6 run nonce). >=0 -> use it as the
        # first value; -1 -> draw a random 31-bit nonce so the echoed values
        # prove THIS run's causality (a board replaying an old 0.. sequence
        # cannot impersonate this run). Default 0 keeps Phase-A determinism.
        self.declare_parameter('start_value', 0)

        rtt_warn_ms = self.get_parameter('rtt_warn_ms').value
        rtt_deadline_ms = self.get_parameter('rtt_deadline_ms').value
        max_inflight = self.get_parameter('max_inflight').value or None
        sweep_period_s = self.get_parameter('sweep_period_s').value
        summary_period_s = self.get_parameter('summary_period_s').value
        settled_window = self.get_parameter('settled_window').value
        self.executor_threads = self.get_parameter('executor_threads').value
        start_value = self.get_parameter('start_value').value

        # §7.6 run nonce: -1 -> random 31-bit nonce; >=0 -> literal start; any
        # other negative is illegal (turning -1 into a real nonce is the node's
        # job, the tracker only accepts a legal [0, 2^31) start).
        if start_value == -1:
            start_seq = random.randrange(2 ** 31)
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

        self._pub = self.create_publisher(Int32, TOPIC_HEARTBEAT, EXO_QOS)
        self._sub = self.create_subscription(
            Int32, TOPIC_STATUS, self._on_status, EXO_QOS,
            callback_group=self._rx_group)
        self._timer = self.create_timer(
            HEARTBEAT_PERIOD_S, self._on_timer,
            callback_group=self._timer_group)
        self._sweep_timer = self.create_timer(
            sweep_period_s, self._on_sweep, callback_group=self._timer_group)
        if summary_period_s and summary_period_s > 0:
            self._summary_timer = self.create_timer(
                summary_period_s, self._on_summary,
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

    # ----- clock -------------------------------------------------------------
    def _now(self) -> float:
        """Monotonic seconds. §7.1: never wall clock (NTP jumps poison RTT)."""
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
        seq, events = self._tracker.on_send(self._now())
        msg = Int32()
        msg.data = seq
        self._pub.publish(msg)
        self.get_logger().debug('sent cmd_heartbeat=%d' % seq)
        # events here are only the (rare) cap-eviction LOST warnings.
        self._emit(events)

    def _on_status(self, msg: Int32):
        events = self._tracker.on_echo(msg.data, self._now())
        self._emit(events)

    def _on_sweep(self):
        # §7.3/M3: settle every entry past its deadline as LOST.
        events = self._tracker.sweep_deadlines(self._now())
        self._emit(events)

    def _on_summary(self):
        # A8: periodic reconciliation snapshot. Loud if the identity breaks
        # (would indicate a silent-drop bug -- must never happen).
        c = self._tracker.counters()
        line = ('link-health summary: sent=%d matched=%d lost=%d '
                'duplicate=%d inflight=%d stale_duplicate=%d'
                % (c['sent'], c['matched'], c['lost'], c['duplicate'],
                   c['inflight'], c['stale_duplicate']))
        if self._tracker.reconciles():
            self.get_logger().info(line)
        else:
            self.get_logger().error(
                'RECONCILE BROKEN (sent != matched+lost+inflight): ' + line)


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
