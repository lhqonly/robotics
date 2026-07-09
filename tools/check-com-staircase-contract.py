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


def row_matches(row: dict[str, str], loop_hz: int, baud: int,
                pc_launch_prefix: str | None) -> bool:
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
    return True


def row_passes(row: dict[str, str]) -> bool:
    return (
        field(row, "verdict") == "PASS"
        and is_zero(row, "lost")
        and is_zero(row, "duplicate")
        and is_zero(row, "qos_incompatibility")
    )


def describe_row(row: dict[str, str]) -> str:
    keys = [
        "stage",
        "verdict",
        "reason",
        "target_rx_hz",
        "pc_wire_gap_p99_ms",
        "pc_wire_gap_max_ms",
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
    args = parser.parse_args()

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

    for loop_hz in args.loops:
        for baud in args.bauds:
            matches = [
                row for row in rows
                if row_matches(row, loop_hz, baud, args.pc_launch_prefix)
            ]
            label = f"loop_hz={loop_hz},baud={baud}"
            if args.pc_launch_prefix is not None:
                label += f",pc_launch_prefix={args.pc_launch_prefix}"
            if not matches:
                failures.append(f"missing_required_stage({label})")
                continue
            passing = [row for row in matches if row_passes(row)]
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
        f"bauds={','.join(str(item) for item in args.bauds)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
