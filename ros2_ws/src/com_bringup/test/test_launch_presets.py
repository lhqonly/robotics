# Copyright 2026 Tom
#
# Licensed under the MIT License.

from pathlib import Path


PKG_ROOT = Path(__file__).parents[1]


def read_launch(name):
    return (PKG_ROOT / 'launch' / name).read_text(encoding='utf-8')


def assert_contains(text, needle):
    assert needle in text, 'missing %r' % needle


def test_latest_target_preset_uses_low_overhead_diagnostics():
    text = read_launch('pc_latest_target.launch.py')

    assert_contains(text, "'cmd_catchup_max': 1")
    assert_contains(text, "'qos_depth': 1")
    assert_contains(text, "'qos_reliability': 'best_effort'")
    assert_contains(text, "'tracking_mode': 'sampled'")
    assert_contains(text, "default_value='1024'")
    assert_contains(text, "default_value='5.0'")
    assert_contains(text, "'summary_period_s': ParameterValue(")
    assert_contains(text, "'link_health_period_s': ParameterValue(")


def test_baseline_pc_cmd_keeps_one_second_diagnostics():
    text = read_launch('pc_cmd.launch.py')

    assert_contains(text, "'cmd_catchup_max',")
    assert_contains(text, "default_value='0'")
    assert_contains(text, "default_value='reliable'")
    assert_contains(text, "default_value='1.0'")
