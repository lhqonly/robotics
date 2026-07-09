import pytest

from motor_tools.joint_model import (
    ControlMode,
    FAULT_INJECTED,
    FAULT_LIMITS_REQUIRED,
    FAULT_POSITION_LIMITED,
    FAULT_TORQUE_LIMITED,
    FAULT_TTL_EXPIRED,
    FAULT_VELOCITY_LIMITED,
    JointTarget,
    TARGET_FLAG_INJECT_FAULT,
)
from motor_tools.mock_motor_backend import MockMotorBackend, MockMotorConfig


def test_mock_state_echoes_target_seq_and_freshness():
    backend = MockMotorBackend(MockMotorConfig(joint_id=7))
    backend.apply_target(JointTarget(
        seq=42,
        joint_id=7,
        control_mode=ControlMode.POSITION,
        position_rad=0.15,
        velocity_rad_s=0.05,
        torque_nm=0.03,
        max_torque_nm=0.2,
        max_velocity_rad_s=0.2,
        min_position_rad=-0.2,
        max_position_rad=0.2,
        ttl_us=1000,
    ), now_us=10_000)

    state = backend.step(now_us=10_500)

    assert state.seq == 1
    assert state.joint_id == 7
    assert state.last_target_seq == 42
    assert state.target_fresh is True
    assert state.enabled is True
    assert state.position_rad == pytest.approx(0.15)


def test_mock_ttl_expiry_disables_target_and_sets_fault():
    backend = MockMotorBackend()
    backend.apply_target(JointTarget(
        seq=9,
        joint_id=0,
        control_mode=ControlMode.VELOCITY,
        velocity_rad_s=0.2,
        max_velocity_rad_s=0.3,
        max_torque_nm=0.2,
        ttl_us=100,
    ), now_us=1_000)

    state = backend.step(now_us=1_101)

    assert state.last_target_seq == 9
    assert state.target_fresh is False
    assert state.enabled is False
    assert state.fault_bits & FAULT_TTL_EXPIRED


def test_mock_limits_position_velocity_and_torque():
    backend = MockMotorBackend()
    backend.apply_target(JointTarget(
        seq=1,
        joint_id=0,
        control_mode=ControlMode.POSITION,
        position_rad=9.0,
        velocity_rad_s=5.0,
        torque_nm=3.0,
        max_torque_nm=0.4,
        max_velocity_rad_s=0.3,
        min_position_rad=-0.2,
        max_position_rad=0.2,
        ttl_us=1000,
    ), now_us=0)

    state = backend.step(now_us=1)

    assert state.position_rad == pytest.approx(0.2)
    assert state.velocity_rad_s == pytest.approx(0.3)
    assert state.torque_est_nm == pytest.approx(0.4)
    assert state.fault_bits & FAULT_POSITION_LIMITED
    assert state.fault_bits & FAULT_VELOCITY_LIMITED
    assert state.fault_bits & FAULT_TORQUE_LIMITED


def test_mock_requires_explicit_limits_before_motion():
    backend = MockMotorBackend()
    backend.apply_target(JointTarget(
        seq=11,
        joint_id=0,
        control_mode=ControlMode.POSITION,
        position_rad=0.15,
        velocity_rad_s=0.05,
        torque_nm=0.03,
        ttl_us=1000,
    ), now_us=0)

    state = backend.step(now_us=1)

    assert state.last_target_seq == 11
    assert state.target_fresh is True
    assert state.enabled is False
    assert state.position_rad == pytest.approx(0.0)
    assert state.velocity_rad_s == pytest.approx(0.0)
    assert state.torque_est_nm == pytest.approx(0.0)
    assert state.fault_bits & FAULT_LIMITS_REQUIRED


def test_mock_fault_injection_latches_and_prevents_enable():
    backend = MockMotorBackend()
    backend.apply_target(JointTarget(
        seq=2,
        joint_id=0,
        control_mode=ControlMode.POSITION,
        flags=TARGET_FLAG_INJECT_FAULT,
        ttl_us=1000,
    ), now_us=0)

    state = backend.step(now_us=1)

    assert state.fault_bits & FAULT_INJECTED
    assert state.enabled is False
    assert state.target_fresh is False
