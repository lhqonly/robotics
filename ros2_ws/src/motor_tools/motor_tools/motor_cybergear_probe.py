"""M0 CyberGear probe entry point with a hardware-free mock mode."""

from __future__ import annotations

import argparse
import json
import sys
import time

from motor_tools.cybergear_backend import (
    CyberGearBackendError,
    CyberGearCanBackend,
    CyberGearCanConfig,
)
from motor_tools.joint_model import ControlMode, JointTarget, TARGET_FLAG_INJECT_FAULT
from motor_tools.mock_motor_backend import MockMotorBackend, MockMotorConfig, monotonic_us


def build_parser() -> argparse.ArgumentParser:
    """Build the command-line parser."""
    parser = argparse.ArgumentParser(description='M0 motor probe tool')
    parser.add_argument('--interface', default='pcan', choices=['pcan', 'socketcan'])
    parser.add_argument('--channel', default='PCAN_USBBUS1')
    parser.add_argument('--bitrate', default=1000000, type=int)
    parser.add_argument('--motor-id', default=127, type=int)
    parser.add_argument('--host-id', default=253, type=int)
    parser.add_argument('--joint-id', default=0, type=int)
    parser.add_argument('--mode', default='probe', choices=['probe', 'mock'])
    parser.add_argument('--samples', default=5, type=int)
    parser.add_argument('--period-s', default=0.05, type=float)
    parser.add_argument('--ttl-us', default=100000, type=int)
    parser.add_argument('--inject-fault-at', default=-1, type=int)
    return parser


def main(argv=None) -> int:
    """Run the probe command."""
    args = build_parser().parse_args(argv)
    if args.mode == 'mock':
        return _run_mock(args)
    return _run_hardware_probe(args)


def _run_mock(args) -> int:
    backend = MockMotorBackend(MockMotorConfig(joint_id=args.joint_id))
    now = monotonic_us()
    backend.apply_target(JointTarget(
        seq=1,
        joint_id=args.joint_id,
        control_mode=ControlMode.POSITION,
        position_rad=0.1,
        velocity_rad_s=0.1,
        torque_nm=0.05,
        max_torque_nm=0.2,
        max_velocity_rad_s=0.2,
        min_position_rad=-0.2,
        max_position_rad=0.2,
        ttl_us=args.ttl_us,
    ), now_us=now)
    for sample in range(max(1, args.samples)):
        sample_now = now + int(sample * args.period_s * 1_000_000)
        if sample == args.inject_fault_at:
            backend.apply_target(JointTarget(
                seq=2,
                joint_id=args.joint_id,
                control_mode=ControlMode.POSITION,
                flags=TARGET_FLAG_INJECT_FAULT,
                ttl_us=args.ttl_us,
            ), now_us=sample_now)
        print(json.dumps(backend.step(now_us=sample_now).as_joint_dict(), sort_keys=True))
        if args.period_s > 0.0 and sample + 1 < args.samples:
            time.sleep(args.period_s)
    return 0


def _run_hardware_probe(args) -> int:
    config = CyberGearCanConfig(
        interface=args.interface,
        channel=args.channel,
        bitrate=args.bitrate,
        motor_id=args.motor_id,
        host_id=args.host_id,
    )
    try:
        with CyberGearCanBackend(config) as backend:
            status = backend.probe()
    except CyberGearBackendError as exc:
        print(f'motor probe failed: {exc}', file=sys.stderr)
        return 2
    status_dict = {
        'seq': 1,
        'joint_id': args.joint_id,
        'control_mode': int(ControlMode.DISABLED),
        'position_rad': status.position_rad,
        'velocity_rad_s': status.velocity_rad_s,
        'torque_est_nm': status.torque_nm,
        'current_a': 0.0,
        'bus_voltage_v': 0.0,
        'temperature_c': status.temperature_c,
        'fault_bits': status.fault_bits,
        'vendor_fault_bits': status.raw_fault_bits,
        'last_target_seq': 0,
        'sample_age_us': 0,
        'enabled': False,
        'target_fresh': False,
    }
    print(json.dumps(status_dict, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
