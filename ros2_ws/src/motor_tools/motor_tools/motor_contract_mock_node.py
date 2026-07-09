"""Minimal ROS mock node for the vendor-neutral /motor contract."""

from __future__ import annotations

from typing import Optional

import rclpy
from rclpy.node import Node

from exo_motor_msgs.msg import JointState, JointTarget, MotorHealth


TARGET_TOPIC = '/motor/tp_joint_target'
STATE_TOPIC = '/motor/tp_joint_state'
HEALTH_TOPIC = '/motor/tp_motor_health'


class MotorContractMockNode(Node):
    """Echo joint targets as mock state and publish bus health counters."""

    def __init__(self):
        super().__init__('node_motor_contract_mock')
        self.declare_parameter('bus_id', 0)
        self.declare_parameter('joint_count', 1)
        self.declare_parameter('publish_period_s', 0.05)

        self._bus_id = self.get_parameter('bus_id').value
        self._joint_count = self.get_parameter('joint_count').value
        publish_period_s = self.get_parameter('publish_period_s').value

        self._state_seq = 0
        self._targets_received = 0
        self._targets_applied = 0
        self._stale_targets = 0
        self._last_target: Optional[JointTarget] = None
        self._last_target_time_ns = 0

        self._state_pub = self.create_publisher(JointState, STATE_TOPIC, 10)
        self._health_pub = self.create_publisher(MotorHealth, HEALTH_TOPIC, 10)
        self.create_subscription(JointTarget, TARGET_TOPIC, self._on_target, 10)
        self.create_timer(float(publish_period_s), self._publish_periodic_samples)

    def _on_target(self, msg: JointTarget):
        self._targets_received += 1
        self._last_target = msg
        self._last_target_time_ns = self.get_clock().now().nanoseconds
        if msg.ttl_us == 0:
            self._stale_targets += 1
        else:
            self._targets_applied += 1
        self._publish_state()
        self._publish_health()

    def _publish_periodic_samples(self):
        self._publish_state()
        self._publish_health()

    def _publish_state(self):
        msg = JointState()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = 'motor_mock'
        self._state_seq = (self._state_seq + 1) % (2 ** 32)
        msg.seq = self._state_seq

        target = self._last_target
        if target is None:
            msg.joint_id = 0
            msg.control_mode = JointState.CONTROL_MODE_DISABLED
            msg.target_fresh = False
            msg.enabled = False
        else:
            age_us = self._target_age_us()
            fresh = target.ttl_us > 0 and age_us <= target.ttl_us
            msg.joint_id = target.joint_id
            msg.control_mode = target.control_mode
            msg.position_rad = target.position_rad
            msg.velocity_rad_s = target.velocity_rad_s
            msg.torque_est_nm = target.torque_nm
            msg.current_a = 0.0
            msg.fault_bits = 0 if fresh else 1
            msg.vendor_fault_bits = 0
            msg.last_target_seq = target.seq
            msg.sample_age_us = age_us
            msg.target_fresh = fresh
            msg.enabled = fresh and target.control_mode != JointTarget.CONTROL_MODE_DISABLED

        msg.bus_voltage_v = 24.0
        msg.temperature_c = 32.0
        self._state_pub.publish(msg)

    def _publish_health(self):
        msg = MotorHealth()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = 'motor_mock'
        msg.bus_id = int(self._bus_id)
        msg.joint_count = int(self._joint_count)
        msg.targets_received = self._targets_received
        msg.targets_applied = self._targets_applied
        msg.stale_targets = self._stale_targets
        msg.motor_tx = self._targets_applied
        msg.motor_rx = self._state_seq
        msg.motor_timeout = 0
        msg.motor_fault = 0
        msg.target_apply_latency_p99_ms = 0.0
        msg.can_gap_p99_ms = 0.0
        msg.reconciles = self._targets_applied <= self._targets_received
        self._health_pub.publish(msg)

    def _target_age_us(self) -> int:
        if self._last_target_time_ns <= 0:
            return 0
        age_ns = self.get_clock().now().nanoseconds - self._last_target_time_ns
        return max(0, age_ns // 1000)


def main(args=None):
    """Run the mock contract node."""
    rclpy.init(args=args)
    node = MotorContractMockNode()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == '__main__':
    main()
