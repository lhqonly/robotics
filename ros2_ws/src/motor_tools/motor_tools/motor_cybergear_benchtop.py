"""M0 benchtop command entry point with guarded hardware behavior."""

from __future__ import annotations

import argparse
import json
import math
import sys
import time

from motor_tools import cybergear_frame_codec as codec
from motor_tools.cybergear_backend import (
    CyberGearBackendError,
    CyberGearCanBackend,
    CyberGearCanConfig,
)
from motor_tools.joint_model import ControlMode, JointTarget, has_explicit_motion_limits
from motor_tools.mock_motor_backend import MockMotorBackend, MockMotorConfig, monotonic_us


def build_parser() -> argparse.ArgumentParser:
    """Build the command-line parser."""
    parser = argparse.ArgumentParser(description='M0 motor benchtop tool')
    parser.add_argument('--interface', default='pcan', choices=['pcan', 'socketcan'])
    parser.add_argument('--channel', default='PCAN_USBBUS1')
    parser.add_argument('--bitrate', default=1000000, type=int)
    parser.add_argument('--motor-id', default=127, type=int)
    parser.add_argument('--host-id', default=253, type=int)
    parser.add_argument('--joint-id', default=0, type=int)
    parser.add_argument(
        '--mode', required=True, choices=['mock', 'position', 'velocity', 'torque'])
    parser.add_argument('--position-rad', default=0.05, type=float)
    parser.add_argument('--velocity-rad-s', default=0.05, type=float)
    parser.add_argument('--torque-nm', default=0.02, type=float)
    parser.add_argument('--max-torque-nm', default=0.0, type=float)
    parser.add_argument('--max-velocity-rad-s', default=0.0, type=float)
    parser.add_argument('--min-position-rad', default=-0.1, type=float)
    parser.add_argument('--max-position-rad', default=0.1, type=float)
    parser.add_argument('--ttl-us', default=100000, type=int)
    parser.add_argument('--seq', default=1, type=int)
    parser.add_argument(
        '--position-dwell-s',
        default=0.2,
        type=float,
        help='dwell time between guarded position round-trip references')
    parser.add_argument(
        '--confirm-motion',
        action='store_true',
        help='explicitly allow enable and a low-amplitude hardware motion command')
    return parser


def main(argv=None) -> int:
    """Run the benchtop command."""
    args = build_parser().parse_args(argv)
    if args.mode == 'mock':
        return _run_mock(args)
    return _run_guarded_hardware(args)


def _target_from_args(args) -> JointTarget:
    mode_map = {
        'mock': ControlMode.POSITION,
        'position': ControlMode.POSITION,
        'velocity': ControlMode.VELOCITY,
        'torque': ControlMode.TORQUE,
    }
    return JointTarget(
        seq=args.seq,
        joint_id=args.joint_id,
        control_mode=mode_map[args.mode],
        position_rad=args.position_rad,
        velocity_rad_s=args.velocity_rad_s,
        torque_nm=args.torque_nm,
        max_torque_nm=args.max_torque_nm,
        max_velocity_rad_s=args.max_velocity_rad_s,
        min_position_rad=args.min_position_rad,
        max_position_rad=args.max_position_rad,
        ttl_us=args.ttl_us,
    )


def _run_mock(args) -> int:
    backend = MockMotorBackend(MockMotorConfig(joint_id=args.joint_id))
    now = monotonic_us()
    backend.apply_target(_target_from_args(args), now_us=now)
    print(json.dumps(backend.step(now_us=now).as_joint_dict(), sort_keys=True))
    print(json.dumps(
        backend.step(now_us=now + args.ttl_us + 1).as_joint_dict(),
        sort_keys=True))
    return 0


def _run_guarded_hardware(args) -> int:
    config = CyberGearCanConfig(
        interface=args.interface,
        channel=args.channel,
        bitrate=args.bitrate,
        motor_id=args.motor_id,
        host_id=args.host_id,
    )
    target = _target_from_args(args)
    try:
        _validate_target_for_hardware(target)
        with CyberGearCanBackend(config) as backend:
            backend.preflight(
                args.max_torque_nm,
                args.max_velocity_rad_s,
                args.min_position_rad,
                args.max_position_rad,
            )
            if not args.confirm_motion:
                raise CyberGearBackendError(
                    'hardware motion requires --confirm-motion; no enable command was sent')
            _send_confirmed_motion(backend, args.mode, target, args.position_dwell_s)
    except CyberGearBackendError as exc:
        print(f'motor benchtop failed: {exc}', file=sys.stderr)
        return 2
    print(json.dumps({
        'joint_id': args.joint_id,
        'mode': args.mode,
        'last_target_seq': args.seq,
        'confirmed_motion_sent': True,
        'enabled': False,
    }, sort_keys=True))
    return 0


def _validate_target_for_hardware(target: JointTarget):
    if not has_explicit_motion_limits(target):
        raise CyberGearBackendError(
            'explicit positive torque/velocity limits and valid position bounds '
            'are required before hardware motion')
    values = (
        target.position_rad,
        target.velocity_rad_s,
        target.torque_nm,
    )
    if not all(math.isfinite(float(value)) for value in values):
        raise CyberGearBackendError('hardware target values must be finite')
    if not target.min_position_rad <= target.position_rad <= target.max_position_rad:
        raise CyberGearBackendError('position target must be inside explicit position bounds')
    if abs(target.velocity_rad_s) > target.max_velocity_rad_s:
        raise CyberGearBackendError('velocity target must be inside explicit velocity limit')
    if abs(target.torque_nm) > target.max_torque_nm:
        raise CyberGearBackendError('torque target must be inside explicit torque limit')
    for position_rad in _position_roundtrip_refs(target):
        if not target.min_position_rad <= position_rad <= target.max_position_rad:
            raise CyberGearBackendError(
                'position round-trip references must fit inside explicit position bounds')


def _send_confirmed_motion(
        backend: CyberGearCanBackend,
        mode: str,
        target: JointTarget,
        position_dwell_s: float):
    motion_error = None
    cleanup_error = None
    cleanup_needed = False
    try:
        backend.send_enable()
        cleanup_needed = True
        if mode == 'position':
            backend.send_run_mode(codec.CyberGearRunMode.POSITION)
            for position_rad in _position_roundtrip_refs(target):
                backend.send_position_reference(position_rad)
                if position_dwell_s > 0.0:
                    time.sleep(position_dwell_s)
        elif mode == 'velocity':
            backend.send_run_mode(codec.CyberGearRunMode.VELOCITY)
            backend.send_velocity_reference(target.velocity_rad_s)
        elif mode == 'torque':
            backend.send_run_mode(codec.CyberGearRunMode.CURRENT)
            backend.send_torque_reference(target.torque_nm)
        else:
            raise CyberGearBackendError(f'unsupported hardware motion mode {mode}')
    except CyberGearBackendError as exc:
        motion_error = exc
    finally:
        if cleanup_needed:
            cleanup_error = _stop_and_disable(backend)
    if motion_error is not None:
        raise motion_error
    if cleanup_error is not None:
        raise cleanup_error


def _position_roundtrip_refs(target: JointTarget):
    amplitude = abs(target.position_rad)
    if amplitude <= 0.0:
        amplitude = min(
            abs(target.min_position_rad),
            abs(target.max_position_rad),
            0.05,
        )
    return (amplitude, -amplitude, 0.0)


def _stop_and_disable(backend: CyberGearCanBackend):
    errors = []
    for action in (backend.send_stop, backend.send_disable):
        try:
            action()
        except CyberGearBackendError as exc:
            errors.append(str(exc))
    if errors:
        return CyberGearBackendError('hardware cleanup failed: ' + '; '.join(errors))
    return None


if __name__ == '__main__':
    raise SystemExit(main())
