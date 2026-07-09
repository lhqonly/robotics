import time

import rclpy
from rclpy.executors import SingleThreadedExecutor
from rclpy.node import Node

from exo_motor_msgs.msg import JointState, JointTarget, MotorHealth
from motor_tools.motor_contract_mock_node import (
    HEALTH_TOPIC,
    STATE_TOPIC,
    TARGET_TOPIC,
    MotorContractMockNode,
)


def test_motor_contract_mock_node_publishes_and_subscribes():
    rclpy.init(args=None)
    executor = SingleThreadedExecutor()
    mock_node = MotorContractMockNode()
    probe_node = Node('node_motor_contract_probe_test')
    received_states = []
    received_health = []

    probe_node.create_subscription(
        JointState, STATE_TOPIC, received_states.append, 10)
    probe_node.create_subscription(
        MotorHealth, HEALTH_TOPIC, received_health.append, 10)
    target_pub = probe_node.create_publisher(JointTarget, TARGET_TOPIC, 10)

    executor.add_node(mock_node)
    executor.add_node(probe_node)

    try:
        assert _publish_until_seen(
            executor, target_pub, received_states, received_health)
        state = next(
            state for state in reversed(received_states)
            if state.last_target_seq == 42 and state.target_fresh)
        health = received_health[-1]

        assert state.last_target_seq == 42
        assert state.joint_id == 2
        assert state.control_mode == JointTarget.CONTROL_MODE_POSITION
        assert state.target_fresh is True
        assert state.enabled is True
        assert health.targets_received >= 1
        assert health.targets_applied >= 1
        assert health.reconciles is True
    finally:
        executor.remove_node(probe_node)
        executor.remove_node(mock_node)
        probe_node.destroy_node()
        mock_node.destroy_node()
        executor.shutdown()
        if rclpy.ok():
            rclpy.shutdown()


def _publish_until_seen(
        executor, target_pub, received_states, received_health) -> bool:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        target_pub.publish(_target_msg())
        step_deadline = min(deadline, time.monotonic() + 0.1)
        while time.monotonic() < step_deadline:
            executor.spin_once(timeout_sec=0.02)
            if _has_matching_samples(received_states, received_health):
                return True
    return False


def _has_matching_samples(received_states, received_health) -> bool:
    return (
        any(
            state.last_target_seq == 42 and state.target_fresh
            for state in received_states)
        and any(health.targets_received >= 1 for health in received_health))


def _target_msg() -> JointTarget:
    msg = JointTarget()
    msg.seq = 42
    msg.joint_id = 2
    msg.control_mode = JointTarget.CONTROL_MODE_POSITION
    msg.position_rad = 0.12
    msg.velocity_rad_s = 0.03
    msg.torque_nm = 0.01
    msg.kp_nm_per_rad = 1.0
    msg.kd_nm_s_per_rad = 0.1
    msg.max_torque_nm = 0.5
    msg.max_velocity_rad_s = 0.5
    msg.max_position_rad = 0.5
    msg.min_position_rad = -0.5
    msg.ttl_us = 10_000_000
    msg.flags = 0
    return msg
