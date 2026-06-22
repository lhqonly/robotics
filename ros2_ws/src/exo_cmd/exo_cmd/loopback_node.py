"""
loopback_node: local stand-in for the MCU (Phase A, no hardware).

Mimics the contract behaviour of the STM32 micro-ROS app (node exo_mcu):
  - subscribes /exo/cmd_heartbeat (exo_msgs/ExoCmd)
  - on each message, echoes it back on /exo/mcu_status as exo_msgs/ExoStatus:
    header.seq is the received cmd.header.seq verbatim; header.stamp_mono_ns is
    OVERWRITTEN with the loopback's own monotonic clock (the MCU re-stamps with
    its own clock, it does NOT echo back the cmd's stamp); payload is the
    received cmd.payload verbatim; header.crc is recomputed when CRC is enabled.

v1.7 (exo_msgs M-A): carrier migrated Int32 -> ExoCmd/ExoStatus. The
FAULT-INJECTION logic (delay / drop / duplicate / drop_seqs / drop_rate / seed)
is UNCHANGED -- only the message type and the dropped-value key (now
msg.header.seq) differ. All injection is OFF by default -> plain echo.

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
import time

from exo_cmd.crc import compute_crc
from exo_cmd.qos import EXO_QOS, qos_summary
from exo_msgs.msg import ExoCmd, ExoStatus
from rcl_interfaces.msg import ParameterDescriptor
import rclpy
from rclpy.node import Node

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
        # CRC self-check switch (Q4 / §7.9). When True, the echoed ExoStatus.crc
        # is recomputed over the re-stamped envelope; when False it is 0. Mirrors
        # exo_cmd's crc_enabled so the round trip stays consistent end to end.
        self.declare_parameter('crc_enabled', False)

        self._delay_ms = float(self.get_parameter('inject_delay_ms').value)
        self._drop_seqs = {int(v) for v in
                           self.get_parameter('drop_seqs').value}
        self._drop_rate = float(self.get_parameter('drop_rate').value)
        self._duplicate = max(0, int(self.get_parameter('duplicate').value))
        seed = int(self.get_parameter('seed').value)
        self._rng = random.Random(seed if seed else None)
        self._crc_enabled = bool(self.get_parameter('crc_enabled').value)
        # Hold one-shot delay timers so they are not garbage-collected before
        # firing; cleaned up when they run.
        self._pending = set()

        self._pub = self.create_publisher(ExoStatus, TOPIC_STATUS, EXO_QOS)
        self._sub = self.create_subscription(
            ExoCmd, TOPIC_HEARTBEAT, self._on_heartbeat, EXO_QOS)

        self.get_logger().info(
            'exo_loopback up (MCU simulator): sub %s -> pub %s (echo)'
            % (TOPIC_HEARTBEAT, TOPIC_STATUS))
        self.get_logger().info(
            'fault-injection: delay_ms=%.1f drop_rate=%.3f duplicate=%d '
            'drop_seqs=%s crc_enabled=%s'
            % (self._delay_ms, self._drop_rate, self._duplicate,
               sorted(self._drop_seqs), self._crc_enabled))
        self.get_logger().info(
            'applied QoS sub[%s]: %s'
            % (TOPIC_HEARTBEAT, qos_summary(self._sub)))
        self.get_logger().info(
            'applied QoS pub[%s]: %s' % (TOPIC_STATUS, qos_summary(self._pub)))

    def _should_drop(self, seq: int) -> bool:
        # Drop decision keys on header.seq (same domain as the sender's seq).
        if seq in self._drop_seqs:
            return True
        if self._drop_rate > 0.0 and self._rng.random() < self._drop_rate:
            return True
        return False

    def _publish_echo(self, seq: int, payload: int) -> None:
        # duplicate copies (§7.5 / A5): publish the SAME seq N times. The MCU
        # re-stamps header.stamp_mono_ns with its OWN monotonic clock (it does
        # NOT echo back the cmd's stamp); payload is returned verbatim.
        stamp_ns = time.monotonic_ns()
        crc = compute_crc(seq, stamp_ns, payload) if self._crc_enabled else 0
        for _ in range(self._duplicate):
            out = ExoStatus()
            out.header.seq = seq          # original seq echo, per contract 1.2
            out.header.stamp_mono_ns = stamp_ns
            out.header.crc = crc
            out.payload = payload         # original payload echo
            self._pub.publish(out)
        self.get_logger().debug(
            'echo seq=%d payload=%d x%d: cmd_heartbeat -> mcu_status'
            % (seq, payload, self._duplicate))

    def _on_heartbeat(self, msg: ExoCmd):
        seq = msg.header.seq
        payload = msg.payload
        if self._should_drop(seq):
            self.get_logger().debug(
                'DROP echo for seq=%d (fault injection)' % seq)
            return
        if self._delay_ms > 0.0:
            self._schedule_delayed_echo(seq, payload)
        else:
            self._publish_echo(seq, payload)

    def _schedule_delayed_echo(self, seq: int, payload: int) -> None:
        # One-shot timer fires once after delay_ms, echoes, then self-cancels.
        delay_s = self._delay_ms / 1000.0

        def _fire():
            timer.cancel()
            self._pending.discard(timer)
            self._publish_echo(seq, payload)

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
