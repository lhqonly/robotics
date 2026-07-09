import json
from types import SimpleNamespace

from motor_tools.cybergear_backend import CyberGearBackendError
from motor_tools import motor_cybergear_benchtop
from motor_tools import motor_cybergear_probe


def test_probe_mock_outputs_joint_state(capsys):
    rc = motor_cybergear_probe.main([
        '--mode', 'mock',
        '--samples', '1',
        '--period-s', '0',
        '--joint-id', '3',
    ])

    captured = capsys.readouterr()

    assert rc == 0
    assert '"joint_id": 3' in captured.out
    assert '"last_target_seq": 1' in captured.out
    assert '"target_fresh": true' in captured.out


def test_probe_hardware_failure_is_clear(monkeypatch, capsys):
    class FailingBackend:
        def __init__(self, _config):
            pass

        def __enter__(self):
            raise CyberGearBackendError('transport unavailable')

        def __exit__(self, _exc_type, _exc, _tb):
            pass

    monkeypatch.setattr(motor_cybergear_probe, 'CyberGearCanBackend', FailingBackend)

    rc = motor_cybergear_probe.main(['--mode', 'probe'])

    captured = capsys.readouterr()

    assert rc == 2
    assert 'motor probe failed: transport unavailable' in captured.err


def test_probe_hardware_outputs_complete_joint_state_fields(monkeypatch, capsys):
    class StatusBackend:
        def __init__(self, _config):
            pass

        def __enter__(self):
            return self

        def __exit__(self, _exc_type, _exc, _tb):
            pass

        def probe(self):
            return SimpleNamespace(
                position_rad=0.1,
                velocity_rad_s=0.2,
                torque_nm=0.03,
                temperature_c=31.5,
                fault_bits=0,
                raw_fault_bits=0,
            )

    monkeypatch.setattr(motor_cybergear_probe, 'CyberGearCanBackend', StatusBackend)

    rc = motor_cybergear_probe.main(['--mode', 'probe', '--joint-id', '4'])

    captured = capsys.readouterr()
    state = json.loads(captured.out)

    assert rc == 0
    assert state == {
        'seq': 1,
        'joint_id': 4,
        'control_mode': 0,
        'position_rad': 0.1,
        'velocity_rad_s': 0.2,
        'torque_est_nm': 0.03,
        'current_a': 0.0,
        'bus_voltage_v': 0.0,
        'temperature_c': 31.5,
        'fault_bits': 0,
        'vendor_fault_bits': 0,
        'last_target_seq': 0,
        'sample_age_us': 0,
        'enabled': False,
        'target_fresh': False,
    }


def test_benchtop_mock_shows_fresh_then_expired(capsys):
    rc = motor_cybergear_benchtop.main([
        '--mode', 'mock',
        '--max-torque-nm', '0.2',
        '--max-velocity-rad-s', '0.2',
        '--ttl-us', '10',
    ])

    captured = capsys.readouterr()

    assert rc == 0
    assert '"target_fresh": true' in captured.out
    assert '"target_fresh": false' in captured.out


def test_benchtop_hardware_without_confirm_does_not_enable(monkeypatch, capsys):
    calls = []

    class GuardedBackend:
        def __init__(self, _config):
            pass

        def __enter__(self):
            return self

        def __exit__(self, _exc_type, _exc, _tb):
            pass

        def preflight(
                self,
                _max_torque_nm,
                _max_velocity_rad_s,
                _min_position_rad,
                _max_position_rad):
            calls.append('preflight')
            return None

        def send_enable(self):
            calls.append('enable')

    monkeypatch.setattr(
        motor_cybergear_benchtop, 'CyberGearCanBackend', GuardedBackend)

    rc = motor_cybergear_benchtop.main([
        '--mode', 'position',
        '--max-torque-nm', '0.1',
        '--max-velocity-rad-s', '0.1',
    ])

    captured = capsys.readouterr()

    assert rc == 2
    assert calls == ['preflight']
    assert 'hardware motion requires --confirm-motion' in captured.err
    assert 'no enable command was sent' in captured.err


def test_benchtop_confirmed_motion_enables_sends_reference_and_disables(
        monkeypatch, capsys):
    calls = []

    class OrderedBackend:
        def __init__(self, _config):
            pass

        def __enter__(self):
            return self

        def __exit__(self, _exc_type, _exc, _tb):
            pass

        def preflight(
                self,
                _max_torque_nm,
                _max_velocity_rad_s,
                _min_position_rad,
                _max_position_rad):
            calls.append('preflight')
            return None

        def send_enable(self):
            calls.append('enable')

        def send_run_mode(self, run_mode):
            calls.append(('run_mode', int(run_mode)))

        def send_position_reference(self, position_rad):
            calls.append(('position', position_rad))

        def send_stop(self):
            calls.append('stop')

        def send_disable(self):
            calls.append('disable')

    monkeypatch.setattr(
        motor_cybergear_benchtop, 'CyberGearCanBackend', OrderedBackend)

    rc = motor_cybergear_benchtop.main([
        '--mode', 'position',
        '--max-torque-nm', '0.1',
        '--max-velocity-rad-s', '0.1',
        '--position-rad', '0.05',
        '--velocity-rad-s', '0.0',
        '--torque-nm', '0.0',
        '--position-dwell-s', '0',
        '--confirm-motion',
    ])

    captured = capsys.readouterr()

    assert rc == 0
    assert calls == [
        'preflight',
        'enable',
        ('run_mode', 1),
        ('position', 0.05),
        ('position', -0.05),
        ('position', 0.0),
        'stop',
        'disable',
    ]
    assert '"confirmed_motion_sent": true' in captured.out
