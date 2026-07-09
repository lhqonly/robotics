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


def best_scheduler(rows: list[dict[str, str]]) -> dict[str, str] | None:
    candidates = [row for row in rows if fnum(row, "pc_wire_gap_p99_ms") is not None]
    if not candidates:
        return None
    return min(
        candidates,
        key=lambda row: (
            fnum(row, "pc_wire_gap_p99_ms") or float("inf"),
            fnum(row, "pc_wire_gap_max_ms") or float("inf"),
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
    parser.add_argument("--staircase-csv", type=Path)
    parser.add_argument("--baud-util-budget-pct", type=float, default=30.0)
    args = parser.parse_args()

    wire_log = args.wire_log or latest_file(ROOT / "log/com-perf", "*.wire.log")
    scheduler_csv = args.scheduler_csv or latest_file(
        ROOT / "log/pc-scheduler-sweep", "*.metrics.csv"
    )
    staircase_csv = args.staircase_csv or latest_file(
        ROOT / "log/com-staircase", "*.metrics.csv"
    )

    wire_metrics = metric_line(wire_log)
    scheduler_rows = read_csv(scheduler_csv)
    staircase_rows = read_csv(staircase_csv)
    latest_200_40_921600 = project_wire(wire_metrics, 200.0, 40, 921600)
    latest_200_40_2m = project_wire(wire_metrics, 200.0, 40, 2_000_000)
    full_echo_200_921600 = project_wire(wire_metrics, 200.0, 1, 921600)
    best_sched = best_scheduler(scheduler_rows)
    qos_bad = qos_incompatibility(staircase_rows)

    print("# Communication Optimization Recommendations")
    print()
    print(f"- wire log: {relpath(wire_log)}")
    print(f"- scheduler CSV: {relpath(scheduler_csv)}")
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
    else:
        print("CANDIDATE wire_budget unavailable=missing_wire_metrics")

    if full_echo_200_921600:
        print(candidate_line(
            "avoid_reliable_full_echo_200hz",
            projected_util_pct=fmt(full_echo_200_921600.util_pct, 2),
            reason="runtime_status_echo_falls_behind",
            adoption="avoid_for_control",
        ))

    if best_sched:
        print(candidate_line(
            "pc_scheduler_best_observed",
            tag=best_sched.get("tag", "unknown"),
            p99_ms=fmt(fnum(best_sched, "pc_wire_gap_p99_ms")),
            max_ms=fmt(fnum(best_sched, "pc_wire_gap_max_ms")),
            adoption="prefer_for_staircase_case",
        ))
    else:
        print("CANDIDATE pc_scheduler_best_observed unavailable=missing_scheduler_csv")

    print(candidate_line(
        "qos_matching_required",
        qos_incompatibility=int(qos_bad),
        adoption="block_latest_target_acceptance_until_zero",
    ))
    print()
    print("## Runtime Gates")
    print()
    print("1. `tools/diagnose-swd.sh` must report `SWD_STATUS=ok`.")
    print("2. Flash the matching best-effort/status40 firmware before judging 200Hz latest-target.")
    print("3. Run staircase with `STAIRCASE_BAUDS=\"921600 2000000\"` and include the best PC scheduler case.")
    print("4. Accept only stages with `qos_incompatibility=0`, `lost=0`, `duplicate=0`, and PC p99/max gap inside contract.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
