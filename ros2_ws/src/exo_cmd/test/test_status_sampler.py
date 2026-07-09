from exo_cmd.link_health import SEQ_MODULUS
from exo_cmd.status_sampler import parse_args, StatusStats
import pytest


def test_status_stats_reports_rate_and_seq_steps():
    stats = StatusStats()

    stats.add(10.00, 100)
    stats.add(10.25, 140)
    stats.add(10.50, 180)

    summary = stats.summary()

    assert 'count=3' in summary
    assert 'rate_hz=4.000' in summary
    assert 'p95_gap_s=0.250' in summary
    assert 'p99_gap_s=0.250' in summary
    assert 'zero_gap_count=0' in summary
    assert 'seq_rate_hz=160.000' in summary
    assert 'seq_delta_avg=40.000' in summary
    assert 'seq_delta_min=40' in summary
    assert 'seq_delta_max=40' in summary


def test_status_stats_seq_steps_are_wrap_safe():
    stats = StatusStats()

    stats.add(1.0, SEQ_MODULUS - 20)
    stats.add(1.1, 10)

    summary = stats.summary()

    assert 'seq_rate_hz=300.000' in summary
    assert 'seq_delta_avg=30.000' in summary
    assert 'seq_delta_min=30' in summary
    assert 'seq_delta_max=30' in summary


def test_status_stats_reports_gap_tail_percentiles():
    stats = StatusStats()

    for index, now_s in enumerate([1.00, 1.01, 1.02, 1.03, 1.20]):
        stats.add(now_s, index)

    summary = stats.summary()

    assert 'max_gap_s=0.170' in summary
    assert 'p95_gap_s=0.170' in summary
    assert 'p99_gap_s=0.170' in summary


def test_status_stats_counts_near_zero_gaps():
    stats = StatusStats()

    stats.add(1.0, 1)
    stats.add(1.0002, 2)
    stats.add(1.0500, 3)

    summary = stats.summary()

    assert 'zero_gap_count=1' in summary


def test_status_sampler_spin_timeout_default_is_low_latency():
    parsed = parse_args([])

    assert parsed.spin_timeout_s == 0.005


def test_status_sampler_rejects_non_positive_spin_timeout():
    with pytest.raises(SystemExit):
        parse_args(['--spin-timeout-s', '0'])
