#!/usr/bin/env python3
"""Summarize communication optimization candidates from existing logs."""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def latest_file(directory: Path, pattern: str) -> Path | None:
    files = list(directory.glob(pattern))
    if not files:
        return None
    return max(files, key=lambda path: path.stat().st_mtime)


def summary_matches_expected_profile(
    summary: Path,
    *,
    cmd_rate_hz: int,
    status_every_n: int,
) -> bool:
    if not summary.exists():
        return False
    profile = ""
    for line in summary.read_text(encoding="utf-8").splitlines():
        if line.startswith("profile "):
            profile = line
    if not profile:
        return False
    required = [
        f"cmd_rate_hz={cmd_rate_hz}",
        "cmd_catchup_max=0",
        "qos=best_effort",
        "tracking=sampled",
        f"status_every_n={status_every_n}",
    ]
    tokens = set(profile.split())
    return all(item in tokens for item in required)


def latest_matching_scheduler_csv(
    directory: Path,
    *,
    cmd_rate_hz: int,
    status_every_n: int,
) -> Path | None:
    files = sorted(
        directory.glob("*.metrics.csv"),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    for csv_path in files:
        summary = csv_path.with_suffix("").with_suffix(".summary.log")
        if summary_matches_expected_profile(
            summary,
            cmd_rate_hz=cmd_rate_hz,
            status_every_n=status_every_n,
        ):
            return csv_path
    return None


def relpath(path: Path | None) -> str:
    if path is None:
        return "-"
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def metric_line(path: Path | None) -> dict[str, float]:
    if path is None or not path.exists():
        return {}
    metrics: dict[str, float] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("METRICS "):
            continue
        for token in line.split()[1:]:
            if "=" not in token:
                continue
            key, value = token.split("=", 1)
            try:
                metrics[key] = float(value.rstrip("%"))
            except ValueError:
                continue
    return metrics


def read_csv(path: Path | None) -> list[dict[str, str]]:
    if path is None or not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def fnum(row: dict[str, str], key: str) -> float | None:
    value = row.get(key, "")
    if value in {"", "NA", "-"}:
        return None
    try:
        return float(value)
    except ValueError:
        return None


def fnum_or_inf(row: dict[str, str], key: str) -> float:
    value = fnum(row, key)
    return value if value is not None else float("inf")


@dataclass
class WireProjection:
    cmd_hz: float
    status_every_n: int
    baud: int
    tx_kbit_s: float
    rx_kbit_s: float
    total_kbit_s: float
    util_pct: float
    cmd_wire_ms: float
    status_wire_ms: float


@dataclass
class MotorProjection:
    target_hz: float
    state_hz: float
    health_hz: float
    baud: int
    tx_kbit_s: float
    rx_kbit_s: float
    total_kbit_s: float
    util_pct: float
    target_wire_ms: float
    state_wire_ms: float
    health_wire_ms: float


def project_wire(metrics: dict[str, float], cmd_hz: float,
                 status_every_n: int, baud: int,
                 baseline_cmd_hz: float = 20.0,
                 baseline_status_hz: float = 20.0) -> WireProjection | None:
    tx_kbit_s = metrics.get("tx_serial_kbit_s")
    rx_kbit_s = metrics.get("rx_serial_kbit_s")
    if tx_kbit_s is None or rx_kbit_s is None:
        return None
    tx_bits_per_cmd = tx_kbit_s * 1000.0 / baseline_cmd_hz
    rx_bits_per_status = rx_kbit_s * 1000.0 / baseline_status_hz
    status_hz = cmd_hz / status_every_n
    projected_tx = tx_bits_per_cmd * cmd_hz / 1000.0
    projected_rx = rx_bits_per_status * status_hz / 1000.0
    total = projected_tx + projected_rx
    return WireProjection(
        cmd_hz=cmd_hz,
        status_every_n=status_every_n,
        baud=baud,
        tx_kbit_s=projected_tx,
        rx_kbit_s=projected_rx,
        total_kbit_s=total,
        util_pct=total * 1000.0 * 100.0 / baud,
        cmd_wire_ms=tx_bits_per_cmd * 1000.0 / baud,
        status_wire_ms=rx_bits_per_status * 1000.0 / baud,
    )


def project_motor_m2(target_hz: float, state_hz: float, health_hz: float,
                     baud: int, xrce_overhead_bytes: float = 32.0
                     ) -> MotorProjection:
    # Empty-frame_id CDR payload sizes from tools/com-wire-budget.py.
    target_bits = (104.0 + xrce_overhead_bytes) * 10.0
    state_bits = (90.0 + xrce_overhead_bytes) * 10.0
    health_bits = (89.0 + xrce_overhead_bytes) * 10.0
    tx = target_bits * target_hz / 1000.0
    rx = state_bits * state_hz / 1000.0 + health_bits * health_hz / 1000.0
    total = tx + rx
    return MotorProjection(
        target_hz=target_hz,
        state_hz=state_hz,
        health_hz=health_hz,
        baud=baud,
        tx_kbit_s=tx,
        rx_kbit_s=rx,
        total_kbit_s=total,
        util_pct=total * 1000.0 * 100.0 / baud,
        target_wire_ms=target_bits * 1000.0 / baud,
        state_wire_ms=state_bits * 1000.0 / baud,
        health_wire_ms=health_bits * 1000.0 / baud,
    )


def best_scheduler(rows: list[dict[str, str]]) -> dict[str, str] | None:
    candidates = [row for row in rows if fnum(row, "pc_wire_gap_p99_ms") is not None]
    if not candidates:
        return None
    return min(
        candidates,
        key=lambda row: (
            fnum_or_inf(row, "pc_wire_gap_p99_ms"),
            fnum_or_inf(row, "pc_wire_gap_max_ms"),
            fnum_or_inf(row, "pc_cmd_catchup_extra"),
            fnum_or_inf(row, "pc_cmd_catchup_events"),
        ),
    )


def lowest_max_scheduler(rows: list[dict[str, str]]) -> dict[str, str] | None:
    candidates = [
        row for row in rows if fnum(row, "pc_wire_gap_max_ms") is not None
    ]
    if not candidates:
        return None
    return min(
        candidates,
        key=lambda row: (
            fnum_or_inf(row, "pc_wire_gap_max_ms"),
            fnum_or_inf(row, "pc_wire_gap_p99_ms"),
            fnum_or_inf(row, "pc_cmd_catchup_extra"),
            fnum_or_inf(row, "pc_cmd_catchup_events"),
        ),
    )


def qos_incompatibility(rows: list[dict[str, str]]) -> bool:
    return any((fnum(row, "qos_incompatibility") or 0.0) > 0.0 for row in rows)


def fmt(value: float | None, digits: int = 3) -> str:
    if value is None:
        return "NA"
    return f"{value:.{digits}f}"


def candidate_line(name: str, **fields: object) -> str:
    parts = [f"CANDIDATE {name}"]
    parts.extend(f"{key}={value}" for key, value in fields.items())
    return " ".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wire-log", type=Path)
    parser.add_argument("--scheduler-csv", type=Path)
    parser.add_argument("--scheduler-logdir", type=Path,
                        default=ROOT / "log/pc-scheduler-sweep")
    parser.add_argument("--exploratory-scheduler-csv", type=Path)
    parser.add_argument("--staircase-csv", type=Path)
    parser.add_argument("--baud-util-budget-pct", type=float, default=30.0)
    args = parser.parse_args()

    wire_log = args.wire_log or latest_file(ROOT / "log/com-perf", "*.wire.log")
    scheduler_csv = args.scheduler_csv or latest_matching_scheduler_csv(
        args.scheduler_logdir,
        cmd_rate_hz=200,
        status_every_n=40,
    )
    exploratory_scheduler_csv = (
        args.exploratory_scheduler_csv or latest_matching_scheduler_csv(
            args.scheduler_logdir,
            cmd_rate_hz=1000,
            status_every_n=200,
        )
    )
    staircase_csv = args.staircase_csv or latest_file(
        ROOT / "log/com-staircase", "*.metrics.csv"
    )

    wire_metrics = metric_line(wire_log)
    scheduler_rows = read_csv(scheduler_csv)
    exploratory_scheduler_rows = read_csv(exploratory_scheduler_csv)
    staircase_rows = read_csv(staircase_csv)
    latest_200_40_921600 = project_wire(wire_metrics, 200.0, 40, 921600)
    latest_200_40_2m = project_wire(wire_metrics, 200.0, 40, 2_000_000)
    full_echo_200_921600 = project_wire(wire_metrics, 200.0, 1, 921600)
    motor_m2_921600 = project_motor_m2(200.0, 50.0, 5.0, 921600)
    motor_m2_2m = project_motor_m2(200.0, 50.0, 5.0, 2_000_000)
    motor_m2_low_921600 = project_motor_m2(200.0, 2.0, 1.0, 921600)
    best_sched = best_scheduler(scheduler_rows)
    low_max_sched = lowest_max_scheduler(scheduler_rows)
    best_exploratory_sched = best_scheduler(exploratory_scheduler_rows)
    qos_bad = qos_incompatibility(staircase_rows)

    print("# Communication Optimization Recommendations")
    print()
    print(f"- wire log: {relpath(wire_log)}")
    print(f"- scheduler CSV: {relpath(scheduler_csv)}")
    print(f"- exploratory scheduler CSV: {relpath(exploratory_scheduler_csv)}")
    print(f"- staircase CSV: {relpath(staircase_csv)}")
    print()
    print("## Current Safe Recommendation")
    print()
    print(
        "RECOMMENDATION control_link=pc_200hz_latest_target_mcu_status_decimated "
        "status_every_n=40 qos=best_effort requires_matching_firmware=1"
    )
    print()
    print("## Candidates")
    print()

    if latest_200_40_921600 and latest_200_40_2m:
        verdict = (
            "PASS_STATIC"
            if latest_200_40_921600.util_pct <= args.baud_util_budget_pct
            else "OVER_BUDGET"
        )
        print(candidate_line(
            "wire_budget_200hz_status40_921600",
            util_pct=fmt(latest_200_40_921600.util_pct, 2),
            total_kbit_s=fmt(latest_200_40_921600.total_kbit_s, 2),
            cmd_wire_ms=fmt(latest_200_40_921600.cmd_wire_ms, 3),
            status_wire_ms=fmt(latest_200_40_921600.status_wire_ms, 3),
            verdict=verdict,
        ))
        improvement = 100.0 * (
            1.0 - latest_200_40_2m.cmd_wire_ms /
            latest_200_40_921600.cmd_wire_ms
        )
        print(candidate_line(
            "baud_2000000_for_200hz_status40",
            util_pct=fmt(latest_200_40_2m.util_pct, 2),
            cmd_wire_ms=fmt(latest_200_40_2m.cmd_wire_ms, 3),
            wire_time_reduction_pct=fmt(improvement, 1),
            adoption="test_after_swd",
        ))
        cmd_saved_ms = (
            latest_200_40_921600.cmd_wire_ms -
            latest_200_40_2m.cmd_wire_ms
        )
        full_echo_921600_ms = (
            latest_200_40_921600.cmd_wire_ms +
            latest_200_40_921600.status_wire_ms
        )
        full_echo_2m_ms = (
            latest_200_40_2m.cmd_wire_ms +
            latest_200_40_2m.status_wire_ms
        )
        print(candidate_line(
            "baud_latency_bound_200hz_status40",
            cmd_wire_ms_921600=fmt(latest_200_40_921600.cmd_wire_ms, 3),
            cmd_wire_ms_2000000=fmt(latest_200_40_2m.cmd_wire_ms, 3),
            cmd_saved_ms=fmt(cmd_saved_ms, 3),
            full_echo_wire_ms_921600=fmt(full_echo_921600_ms, 3),
            full_echo_wire_ms_2000000=fmt(full_echo_2m_ms, 3),
            cannot_explain_20ms=1,
            adoption="optimize_qos_scheduler_spin_before_baud_only",
        ))
    else:
        print("CANDIDATE wire_budget unavailable=missing_wire_metrics")

    if full_echo_200_921600:
        print(candidate_line(
            "avoid_reliable_full_echo_200hz",
            projected_util_pct=fmt(full_echo_200_921600.util_pct, 2),
            reason="runtime_status_echo_falls_behind",
            adoption="avoid_for_control",
        ))

    motor_verdict_921600 = (
        "PASS_STATIC"
        if motor_m2_921600.util_pct <= args.baud_util_budget_pct
        else "OVER_BUDGET"
    )
    motor_verdict_2m = (
        "PASS_STATIC"
        if motor_m2_2m.util_pct <= args.baud_util_budget_pct
        else "OVER_BUDGET"
    )
    print(candidate_line(
        "motor_m2_wire_budget_200hz_state50_health5_921600",
        util_pct=fmt(motor_m2_921600.util_pct, 2),
        total_kbit_s=fmt(motor_m2_921600.total_kbit_s, 2),
        target_wire_ms=fmt(motor_m2_921600.target_wire_ms, 3),
        state_wire_ms=fmt(motor_m2_921600.state_wire_ms, 3),
        health_wire_ms=fmt(motor_m2_921600.health_wire_ms, 3),
        verdict=motor_verdict_921600,
        adoption="test_after_swd",
    ))
    print(candidate_line(
        "motor_m2_wire_budget_200hz_state50_health5_2000000",
        util_pct=fmt(motor_m2_2m.util_pct, 2),
        total_kbit_s=fmt(motor_m2_2m.total_kbit_s, 2),
        target_wire_ms=fmt(motor_m2_2m.target_wire_ms, 3),
        state_wire_ms=fmt(motor_m2_2m.state_wire_ms, 3),
        health_wire_ms=fmt(motor_m2_2m.health_wire_ms, 3),
        verdict=motor_verdict_2m,
        adoption="prefer_if_921600_runtime_margin_is_poor",
    ))
    print(candidate_line(
        "motor_m2_wire_budget_200hz_state2_health1_921600",
        util_pct=fmt(motor_m2_low_921600.util_pct, 2),
        total_kbit_s=fmt(motor_m2_low_921600.total_kbit_s, 2),
        target_wire_ms=fmt(motor_m2_low_921600.target_wire_ms, 3),
        state_wire_ms=fmt(motor_m2_low_921600.state_wire_ms, 3),
        health_wire_ms=fmt(motor_m2_low_921600.health_wire_ms, 3),
        verdict=(
            "PASS_STATIC"
            if motor_m2_low_921600.util_pct <= args.baud_util_budget_pct
            else "OVER_BUDGET"
        ),
        adoption="test_as_921600_low_telemetry_profile_after_default_2mbps_smoke",
    ))

    if best_sched:
        print(candidate_line(
            "pc_scheduler_best_observed",
            tag=best_sched.get("tag", "unknown"),
            p99_ms=fmt(fnum(best_sched, "pc_wire_gap_p99_ms")),
            max_ms=fmt(fnum(best_sched, "pc_wire_gap_max_ms")),
            catchup_events=fmt(fnum(best_sched, "pc_cmd_catchup_events"), 0),
            catchup_extra=fmt(fnum(best_sched, "pc_cmd_catchup_extra"), 0),
            adoption="prefer_for_staircase_case",
        ))
        if low_max_sched and low_max_sched != best_sched:
            print(candidate_line(
                "pc_scheduler_lowest_max_observed",
                tag=low_max_sched.get("tag", "unknown"),
                p99_ms=fmt(fnum(low_max_sched, "pc_wire_gap_p99_ms")),
                max_ms=fmt(fnum(low_max_sched, "pc_wire_gap_max_ms")),
                catchup_events=fmt(
                    fnum(low_max_sched, "pc_cmd_catchup_events"), 0),
                catchup_extra=fmt(
                    fnum(low_max_sched, "pc_cmd_catchup_extra"), 0),
                adoption="compare_when_tail_max_matters",
            ))
    else:
        print("CANDIDATE pc_scheduler_best_observed unavailable=missing_scheduler_csv")

    if best_exploratory_sched:
        print(candidate_line(
            "pc_scheduler_1000hz_exploratory",
            tag=best_exploratory_sched.get("tag", "unknown"),
            p99_ms=fmt(fnum(best_exploratory_sched, "pc_wire_gap_p99_ms")),
            max_ms=fmt(fnum(best_exploratory_sched, "pc_wire_gap_max_ms")),
            catchup_events=fmt(
                fnum(best_exploratory_sched, "pc_cmd_catchup_events"), 0),
            catchup_extra=fmt(
                fnum(best_exploratory_sched, "pc_cmd_catchup_extra"), 0),
            adoption="explore_only_not_staircase_default",
        ))

    print(candidate_line(
        "qos_matching_required",
        qos_incompatibility=int(qos_bad),
        adoption="block_latest_target_acceptance_until_zero",
    ))
    print(candidate_line(
        "staircase_acceptance_contract",
        required="max_pc_catchup_events=0,max_pc_catchup_extra=0,rate_and_gap_defaults",
        optional_wire=f"max_wire_baud_util_pct={args.baud_util_budget_pct:g}",
        adoption="run_after_staircase",
    ))
    print()
    print("## Runtime Gates")
    print()
    print("1. `tools/diagnose-swd.sh` must report `SWD_STATUS=ok`.")
    print("2. Flash the matching best-effort/status40 firmware before judging 200Hz latest-target.")
    print("3. Run staircase with `STAIRCASE_BAUDS=\"921600 2000000\"` and include the best PC scheduler case plus M2 motor topics.")
    print("4. Run `tools/check-com-staircase-contract.py <metrics.csv> --max-pc-catchup-events 0 --max-pc-catchup-extra 0`; add `--max-wire-baud-util-pct 30` when wire metrics were collected.")
    print("5. Accept only stages with `qos_incompatibility=0`, `lost=0`, `duplicate=0`, 200Hz target/window rate inside contract, PC p99/max gap inside contract, and zero catch-up bursts.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
