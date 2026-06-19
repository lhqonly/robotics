"""
loopback_node: local stand-in for the MCU (Phase A, no hardware).

Mimics the contract behaviour of the STM32 micro-ROS app (node exo_mcu):
  - subscribes /exo/cmd_heartbeat (std_msgs/Int32)
  - on each message, publishes the SAME value back on /exo/mcu_status.

v1.1: adds configurable FAULT INJECTION so Gill can drive the link-health
verification (contract §7.8, A1-A7) with no hardware: inject latency, drop
echoes, and duplicate echoes. All injection is OFF by default -> plain echo,
identical to v1.0 wire behaviour.

Fault-injection ROS params
  inject_delay_ms (double, default 0.0)
      Delay each echo by this many ms (one-shot timer). 0 = immediate.
      Use to exercise A1 (RTT≈D) and A2 (delay > rtt_warn_ms -> WARN).
  drop_seqs (int array, default [])
      Specific heartbeat values whose echo is dropped (never sent). Use for
      A3 (deterministic loss) and A4 (force in-flight backlog).
  drop_rate (double 0..1, default 0.0)
      Probabilistic echo drop. Use for A4 backlog / statistical loss.
  duplicate (int, default 1)
      How many copies of each (non-dropped) echo to publish. 1 = normal,
      2 = one duplicate, etc. Use for A5 (duplicate echo handling).
  seed (int, default 0)
      RNG seed for drop_rate, for reproducible runs. 0 = system entropy.

Node name 'exo_loopback' (not 'exo_mcu') so it never collides with the real
firmware node on Phase B; the topic wire behaviour is identical.
"""

import random

from exo_cmd.qos import EXO_QOS, qos_summary
from rcl_interfaces.msg import ParameterDescriptor
import rclpy
from rclpy.node import Node
from std_msgs.msg import Int32

TOPIC_HEARTBEAT = '/exo/cmd_heartbeat'
TOPIC_STATUS = '/exo/mcu_status'


class LoopbackNode(Node):
    def __init__(self):
        super().__init__('exo_loopback')

        # ----- fault-injection params (all default to "no fault") -----
        self.declare_parameter('inject_delay_ms', 0.0)
        # drop_seqs: heartbeat values whose echo is dropped. Default [] = drop
        # nothing.
        #
        # Jazzy gotcha: an empty-list default makes rclpy *infer* the param type
        # as BYTE_ARRAY at declaration time, and a ParameterDescriptor(type=
        # PARAMETER_INTEGER_ARRAY) does NOT override that inferred type. So
        # `-p drop_seqs:="[5,6,7]"` (INTEGER_ARRAY) gets rejected at startup
        # with InvalidParameterTypeException (expecting BYTE_ARRAY). Fix: use
        # dynamic_typing=True so the type is not locked at declaration; the
        # type is taken from whatever value is actually set at runtime. Default
        # stays the empty list -> empty set -> drop nothing.
        self.declare_parameter(
            'drop_seqs', [],
            ParameterDescriptor(dynamic_typing=True))
        self.declare_parameter('drop_rate', 0.0)
        self.declare_parameter('duplicate', 1)
        self.declare_parameter('seed', 0)

        self._delay_ms = float(self.get_parameter('inject_delay_ms').value)
        self._drop_seqs = {int(v) for v in
                           self.get_parameter('drop_seqs').value}
        self._drop_rate = float(self.get_parameter('drop_rate').value)
        self._duplicate = max(0, int(self.get_parameter('duplicate').value))
        seed = int(self.get_parameter('seed').value)
        self._rng = random.Random(seed if seed else None)
        # Hold one-shot delay timers so they are not garbage-collected before
        # firing; cleaned up when they run.
        self._pending = set()

        self._pub = self.create_publisher(Int32, TOPIC_STATUS, EXO_QOS)
        self._sub = self.create_subscription(
            Int32, TOPIC_HEARTBEAT, self._on_heartbeat, EXO_QOS)

        self.get_logger().info(
            'exo_loopback up (MCU simulator): sub %s -> pub %s (echo)'
            % (TOPIC_HEARTBEAT, TOPIC_STATUS))
        self.get_logger().info(
            'fault-injection: delay_ms=%.1f drop_rate=%.3f duplicate=%d '
            'drop_seqs=%s' % (self._delay_ms, self._drop_rate,
                              self._duplicate, sorted(self._drop_seqs)))
        self.get_logger().info(
            'applied QoS sub[%s]: %s'
            % (TOPIC_HEARTBEAT, qos_summary(self._sub)))
        self.get_logger().info(
            'applied QoS pub[%s]: %s' % (TOPIC_STATUS, qos_summary(self._pub)))

    def _should_drop(self, value: int) -> bool:
        if value in self._drop_seqs:
            return True
        if self._drop_rate > 0.0 and self._rng.random() < self._drop_rate:
            return True
        return False

    def _publish_echo(self, value: int) -> None:
        # duplicate copies (§7.5 / A5): publish the same value N times.
        for _ in range(self._duplicate):
            out = Int32()
            out.data = value  # original-value echo, per contract 1.2
            self._pub.publish(out)
        self.get_logger().debug(
            'echo %d x%d: cmd_heartbeat -> mcu_status'
            % (value, self._duplicate))

    def _on_heartbeat(self, msg: Int32):
        value = msg.data
        if self._should_drop(value):
            self.get_logger().debug('DROP echo for %d (fault injection)' % value)
            return
        if self._delay_ms > 0.0:
            self._schedule_delayed_echo(value)
        else:
            self._publish_echo(value)

    def _schedule_delayed_echo(self, value: int) -> None:
        # One-shot timer fires once after delay_ms, echoes, then self-cancels.
        delay_s = self._delay_ms / 1000.0

        def _fire():
            timer.cancel()
            self._pending.discard(timer)
            self._publish_echo(value)

        timer = self.create_timer(delay_s, _fire)
        self._pending.add(timer)


def main(args=None):
    rclpy.init(args=args)
    node = LoopbackNode()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == '__main__':
    main()
