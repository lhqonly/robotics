#!/usr/bin/env python3
"""Check that a full communication staircase matrix satisfies acceptance gates."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def latest_csv() -> Path | None:
    logdir = ROOT / "log/com-staircase"
    files = list(logdir.glob("*.metrics.csv"))
    if not files:
        return None
    return max(files, key=lambda path: path.stat().st_mtime)


def parse_int_list(raw: str) -> list[int]:
    values: list[int] = []
    for item in raw.replace(",", " ").split():
        values.append(int(item))
    if not values:
        raise argparse.ArgumentTypeError("expected at least one integer")
    return values


def read_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def field(row: dict[str, str], name: str) -> str:
    value = row.get(name, "")
    return value if value != "" else "NA"


def is_zero(row: dict[str, str], name: str) -> bool:
    try:
        return float(field(row, name)) == 0.0
    except ValueError:
        return False


def numeric_lte(row: dict[str, str], name: str, maximum: float) -> bool:
    try:
        return float(field(row, name)) <= maximum
    except ValueError:
        return False


def numeric_between(row: dict[str, str], name: str,
                    minimum: float, maximum: float) -> bool:
    try:
        value = float(field(row, name))
    except ValueError:
        return False
    return minimum <= value <= maximum


def optional_numeric_lte(row: dict[str, str],
                         name: str,
                         maximum: float | None) -> bool:
    if maximum is None:
        return True
    return numeric_lte(row, name, maximum)


def row_matches(row: dict[str, str], loop_hz: int, baud: int,
                pc_launch_prefix: str | None,
                pc_executor_threads: int | None,
                executor_spin_timeout_us: int | None) -> bool:
    if field(row, "loop_hz") != str(loop_hz):
        return False
    if field(row, "baud") != str(baud):
        return False
    if field(row, "pc_cmd_hz") != "200":
        return False
    if field(row, "qos") != "best_effort":
        return False
    if field(row, "status_every_n") != "40":
        return False
    if pc_launch_prefix is not None and field(row, "pc_launch_prefix") != pc_launch_prefix:
        return False
    if (
        pc_executor_threads is not None
        and field(row, "pc_executor_threads") != str(pc_executor_threads)
    ):
        return False
    if (
        executor_spin_timeout_us is not None
        and field(row, "executor_spin_timeout_us") != str(executor_spin_timeout_us)
    ):
        return False
    return True


def row_passes(row: dict[str, str],
               max_pc_catchup_events: float,
               max_pc_catchup_extra: float,
               min_target_rx_hz: float,
               max_target_rx_hz: float,
               min_pc_target_window_hz: float,
               max_pc_target_window_hz: float,
               max_pc_wire_gap_p99_ms: float,
               max_pc_wire_gap_max_ms: float,
               max_wire_baud_util_pct: float | None) -> bool:
    return (
        field(row, "verdict") == "PASS"
        and numeric_between(
            row, "target_rx_hz", min_target_rx_hz, max_target_rx_hz
        )
        and numeric_between(
            row, "pc_target_window_hz",
            min_pc_target_window_hz,
            max_pc_target_window_hz,
        )
        and numeric_lte(row, "pc_wire_gap_p99_ms", max_pc_wire_gap_p99_ms)
        and numeric_lte(row, "pc_wire_gap_max_ms", max_pc_wire_gap_max_ms)
        and optional_numeric_lte(
            row, "wire_baud_util_pct", max_wire_baud_util_pct
        )
        and is_zero(row, "lost")
        and is_zero(row, "duplicate")
        and is_zero(row, "qos_incompatibility")
        and numeric_lte(row, "pc_cmd_catchup_events", max_pc_catchup_events)
        and numeric_lte(row, "pc_cmd_catchup_extra", max_pc_catchup_extra)
    )


def describe_row(row: dict[str, str]) -> str:
    keys = [
        "stage",
        "verdict",
        "reason",
        "target_rx_hz",
        "pc_wire_gap_p99_ms",
        "pc_wire_gap_max_ms",
        "pc_cmd_catchup_events",
        "pc_cmd_catchup_extra",
        "wire_baud_util_pct",
        "lost",
        "duplicate",
        "qos_incompatibility",
    ]
    return " ".join(f"{key}={field(row, key)}" for key in keys)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", nargs="?", type=Path)
    parser.add_argument("--loops", type=parse_int_list, default=parse_int_list("1000 2000 5000 10000"))
    parser.add_argument("--bauds", type=parse_int_list, default=parse_int_list("921600 2000000"))
    parser.add_argument("--pc-launch-prefix")
    parser.add_argument("--pc-executor-threads", type=int)
    parser.add_argument("--executor-spin-timeout-us", type=int)
    parser.add_argument("--max-pc-catchup-events", type=float, default=0.0)
    parser.add_argument("--max-pc-catchup-extra", type=float, default=0.0)
    parser.add_argument("--expected-pc-cmd-hz", type=float, default=200.0)
    parser.add_argument("--min-rate-ratio", type=float, default=0.90)
    parser.add_argument("--max-rate-ratio", type=float, default=1.10)
    parser.add_argument("--max-pc-p99-gap-ratio", type=float, default=4.0)
    parser.add_argument("--max-pc-max-gap-ratio", type=float, default=10.0)
    parser.add_argument("--max-wire-baud-util-pct", type=float)
    args = parser.parse_args()

    if args.expected_pc_cmd_hz <= 0:
        print("FAIL com_staircase_contract reason=invalid_expected_pc_cmd_hz")
        return 1
    if args.min_rate_ratio <= 0 or args.max_rate_ratio < args.min_rate_ratio:
        print("FAIL com_staircase_contract reason=invalid_rate_ratio")
        return 1
    if args.max_pc_p99_gap_ratio <= 0 or args.max_pc_max_gap_ratio <= 0:
        print("FAIL com_staircase_contract reason=invalid_gap_ratio")
        return 1
    if (
        args.max_wire_baud_util_pct is not None
        and args.max_wire_baud_util_pct <= 0
    ):
        print("FAIL com_staircase_contract reason=invalid_wire_baud_util_pct")
        return 1

    csv_path = args.csv or latest_csv()
    if csv_path is None:
        print("FAIL com_staircase_contract reason=missing_csv")
        return 1
    if not csv_path.exists():
        print(f"FAIL com_staircase_contract reason=csv_not_found csv={csv_path}")
        return 1

    rows = read_rows(csv_path)
    failures: list[str] = []
    pass_count = 0
    min_target_rx_hz = args.expected_pc_cmd_hz * args.min_rate_ratio
    max_target_rx_hz = args.expected_pc_cmd_hz * args.max_rate_ratio
    min_pc_target_window_hz = args.expected_pc_cmd_hz * args.min_rate_ratio
    max_pc_target_window_hz = args.expected_pc_cmd_hz * args.max_rate_ratio
    period_ms = 1000.0 / args.expected_pc_cmd_hz
    max_pc_wire_gap_p99_ms = period_ms * args.max_pc_p99_gap_ratio
    max_pc_wire_gap_max_ms = period_ms * args.max_pc_max_gap_ratio

    for loop_hz in args.loops:
        for baud in args.bauds:
            matches = [
                row for row in rows
                if row_matches(
                    row,
                    loop_hz,
                    baud,
                    args.pc_launch_prefix,
                    args.pc_executor_threads,
                    args.executor_spin_timeout_us,
                )
            ]
            label = f"loop_hz={loop_hz},baud={baud}"
            if args.pc_launch_prefix is not None:
                label += f",pc_launch_prefix={args.pc_launch_prefix}"
            if args.pc_executor_threads is not None:
                label += f",pc_executor_threads={args.pc_executor_threads}"
            if args.executor_spin_timeout_us is not None:
                label += f",executor_spin_timeout_us={args.executor_spin_timeout_us}"
            if not matches:
                failures.append(f"missing_required_stage({label})")
                continue
            passing = [
                row for row in matches
                if row_passes(
                    row,
                    args.max_pc_catchup_events,
                    args.max_pc_catchup_extra,
                    min_target_rx_hz,
                    max_target_rx_hz,
                    min_pc_target_window_hz,
                    max_pc_target_window_hz,
                    max_pc_wire_gap_p99_ms,
                    max_pc_wire_gap_max_ms,
                    args.max_wire_baud_util_pct,
                )
            ]
            if not passing:
                failures.append(
                    f"no_passing_stage({label}; {' | '.join(describe_row(row) for row in matches)})"
                )
                continue
            pass_count += 1

    required_count = len(args.loops) * len(args.bauds)
    if failures:
        print(
            "FAIL com_staircase_contract "
            f"csv={csv_path} passed={pass_count}/{required_count} "
            f"reason={';'.join(failures)}"
        )
        return 1

    print(
        "PASS com_staircase_contract "
        f"csv={csv_path} passed={pass_count}/{required_count} "
        f"loops={','.join(str(item) for item in args.loops)} "
        f"bauds={','.join(str(item) for item in args.bauds)} "
        f"target_rx_hz_range={min_target_rx_hz:g}..{max_target_rx_hz:g} "
        f"pc_target_window_hz_range={min_pc_target_window_hz:g}..{max_pc_target_window_hz:g} "
        f"pc_wire_gap_p99_ms_max={max_pc_wire_gap_p99_ms:g} "
        f"pc_wire_gap_max_ms_max={max_pc_wire_gap_max_ms:g} "
        f"max_wire_baud_util_pct={args.max_wire_baud_util_pct if args.max_wire_baud_util_pct is not None else 'NA'} "
        f"max_pc_catchup_events={args.max_pc_catchup_events:g} "
        f"max_pc_catchup_extra={args.max_pc_catchup_extra:g}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
