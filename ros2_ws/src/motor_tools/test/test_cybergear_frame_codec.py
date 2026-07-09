import struct

import pytest

from motor_tools import cybergear_frame_codec as codec


def test_enable_disable_stop_and_zero_encode_command_frames():
    enable = codec.make_enable_frame(motor_id=127, host_id=253)
    disable = codec.make_disable_frame(motor_id=127, host_id=253, clear_fault=True)
    stop = codec.make_stop_frame(motor_id=127, host_id=253)
    zero = codec.make_set_zero_frame(motor_id=127, host_id=253)

    assert codec.split_extended_id(enable.arbitration_id) == (
        codec.CyberGearCommand.ENABLE, 127, 253)
    assert codec.split_extended_id(disable.arbitration_id) == (
        codec.CyberGearCommand.STOP, 127, 253)
    assert disable.data[0] == 1
    assert codec.split_extended_id(stop.arbitration_id)[0] == codec.CyberGearCommand.STOP
    assert codec.split_extended_id(zero.arbitration_id)[0] == codec.CyberGearCommand.SET_ZERO
    assert zero.data[0] == 1


def test_motion_frame_encodes_position_velocity_torque_kp_kd():
    frame = codec.make_motion_frame(
        motor_id=1,
        host_id=253,
        torque_nm=1.5,
        position_rad=0.25,
        velocity_rad_s=-0.5,
        kp=20.0,
        kd=0.2,
    )

    command, motor_id, torque_u16 = codec.split_extended_id(frame.arbitration_id)
    assert command == codec.CyberGearCommand.CONTROL
    assert motor_id == 1
    assert codec.uint_to_float(
        torque_u16, codec.T_MIN_NM, codec.T_MAX_NM, 16) == pytest.approx(1.5, abs=0.001)
    assert codec.uint_to_float(
        int.from_bytes(frame.data[0:2], 'big'),
        codec.P_MIN_RAD, codec.P_MAX_RAD, 16) == pytest.approx(0.25, abs=0.001)
    assert codec.uint_to_float(
        int.from_bytes(frame.data[2:4], 'big'),
        codec.V_MIN_RAD_S, codec.V_MAX_RAD_S, 16) == pytest.approx(-0.5, abs=0.001)


def test_position_velocity_current_and_torque_parameter_writes():
    position = codec.make_position_frame(2, 253, 0.125)
    velocity = codec.make_velocity_frame(2, 253, 0.25)
    current = codec.make_current_frame(2, 253, 1.5)
    torque = codec.make_torque_frame(2, 253, torque_nm=0.36, torque_constant_nm_per_a=0.18)
    run_mode = codec.make_run_mode_frame(2, 253, codec.CyberGearRunMode.VELOCITY)

    assert position.data[:2] == codec.POSITION_REF_PARAM_INDEX.to_bytes(2, 'little')
    assert struct.unpack('<f', position.data[4:8])[0] == pytest.approx(0.125)
    assert velocity.data[:2] == codec.VELOCITY_REF_PARAM_INDEX.to_bytes(2, 'little')
    assert current.data[:2] == codec.CURRENT_REF_PARAM_INDEX.to_bytes(2, 'little')
    assert struct.unpack('<f', current.data[4:8])[0] == pytest.approx(1.5)
    assert struct.unpack('<f', torque.data[4:8])[0] == pytest.approx(2.0)
    assert run_mode.data[:4] == codec.RUN_MODE_PARAM_INDEX.to_bytes(4, 'little')
    assert run_mode.data[4] == int(codec.CyberGearRunMode.VELOCITY)
    assert run_mode.data[5:8] == bytes(3)


def test_status_frame_parses_values_and_faults():
    raw_faults = 0b000101
    arbitration_id = codec.make_extended_id(
        codec.CyberGearCommand.FEEDBACK,
        motor_id=127,
        data_field=(raw_faults << 8) | 253,
    )
    data = b''.join([
        codec.float_to_uint(0.5, codec.P_MIN_RAD, codec.P_MAX_RAD, 16).to_bytes(2, 'big'),
        codec.float_to_uint(-1.0, codec.V_MIN_RAD_S, codec.V_MAX_RAD_S, 16).to_bytes(2, 'big'),
        codec.float_to_uint(0.75, codec.T_MIN_NM, codec.T_MAX_NM, 16).to_bytes(2, 'big'),
        int(36.5 * codec.TEMP_SCALE_C).to_bytes(2, 'big'),
    ])

    status = codec.parse_status_frame(codec.CyberGearFrame(arbitration_id, data))

    assert status.motor_id == 127
    assert status.host_id == 253
    assert status.position_rad == pytest.approx(0.5, abs=0.001)
    assert status.velocity_rad_s == pytest.approx(-1.0, abs=0.001)
    assert status.torque_nm == pytest.approx(0.75, abs=0.001)
    assert status.temperature_c == pytest.approx(36.5)
    assert status.raw_fault_bits == raw_faults
    assert status.fault_bits & codec.FAULT_UNDERVOLTAGE
    assert status.fault_bits & codec.FAULT_OVERTEMPERATURE


def test_parse_rejects_non_feedback_frame():
    frame = codec.make_enable_frame(127, 253)
    with pytest.raises(codec.CyberGearCodecError):
        codec.parse_status_frame(frame)


def test_split_rejects_unknown_command_with_codec_error():
    unknown_command_id = (31 << 24) | (253 << 8) | 127

    with pytest.raises(codec.CyberGearCodecError, match='unknown CyberGear command'):
        codec.split_extended_id(unknown_command_id)
