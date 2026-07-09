#!/usr/bin/env python3
"""Sweep M2 motor telemetry periods against the static UART budget."""

from __future__ import annotations

import argparse
import importlib.util
import math
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WIRE_BUDGET = ROOT / "tools" / "com-wire-budget.py"
STATE_PERIOD_DEFAULT = "20 50 100 200 500 1000"
HEALTH_PERIOD_DEFAULT = "200 500 1000 2000 5000"
BAUD_DEFAULT = "921600 2000000"
STATE_PERIOD_MIN_MS = 10
STATE_PERIOD_MAX_MS = 1000
HEALTH_PERIOD_MIN_MS = 100
HEALTH_PERIOD_MAX_MS = 5000


def load_wire_budget():
    spec = importlib.util.spec_from_file_location("com_wire_budget", WIRE_BUDGET)
    if spec is None or spec.loader is None:
        raise SystemExit(f"ERROR: cannot load {WIRE_BUDGET}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


wire_budget = load_wire_budget()


@dataclass(frozen=True)
class Row:
    state_ms: int
    health_ms: int
    baud: int
    state_hz: float
    health_hz: float
    tx_kbit_s: float
    rx_kbit_s: float
    total_kbit_s: float
    util_pct: float
    margin_pct: float
    verdict: str
    min_baud: int
    target_wire_ms: float
    state_wire_ms: float
    health_wire_ms: float


def parse_int_list(raw: str, label: str) -> list[int]:
    values: list[int] = []
    for item in raw.replace(",", " ").split():
        try:
            values.append(int(item))
        except ValueError as exc:
            raise argparse.ArgumentTypeError(
                f"{label} expects integers, got {item!r}"
            ) from exc
    if not values:
        raise argparse.ArgumentTypeError(f"{label} expects at least one integer")
    return values


def parse_state_periods(raw: str) -> list[int]:
    values = parse_int_list(raw, "--state-period-ms")
    invalid = [
        value for value in values
        if value < STATE_PERIOD_MIN_MS or value > STATE_PERIOD_MAX_MS
    ]
    if invalid:
        raise argparse.ArgumentTypeError(
            "--state-period-ms values must be in "
            f"[{STATE_PERIOD_MIN_MS}, {STATE_PERIOD_MAX_MS}]"
        )
    return values


def parse_health_periods(raw: str) -> list[int]:
    values = parse_int_list(raw, "--health-period-ms")
    invalid = [
        value for value in values
        if value < HEALTH_PERIOD_MIN_MS or value > HEALTH_PERIOD_MAX_MS
    ]
    if invalid:
        raise argparse.ArgumentTypeError(
            "--health-period-ms values must be in "
            f"[{HEALTH_PERIOD_MIN_MS}, {HEALTH_PERIOD_MAX_MS}]"
        )
    return values


def parse_bauds(raw: str) -> list[int]:
    values = parse_int_list(raw, "--baud")
    if any(value <= 0 for value in values):
        raise argparse.ArgumentTypeError("--baud values must be > 0")
    return values


def fmt(value: float, digits: int = 2) -> str:
    return f"{value:.{digits}f}"


def project_rows(
    *,
    cmd_hz: float,
    state_periods: list[int],
    health_periods: list[int],
    bauds: list[int],
    max_baud_util_pct: float,
    xrce_overhead_bytes: float,
) -> list[Row]:
    payload = wire_budget.motor_m2_payload_sizes()
    serial_bytes = {
        name: payload_bytes + xrce_overhead_bytes
        for name, payload_bytes in payload.items()
    }
    target_bits = serial_bytes["JointTarget"] * 10.0
    state_bits = serial_bytes["JointState"] * 10.0
    health_bits = serial_bytes["MotorHealth"] * 10.0
    rows: list[Row] = []
    for state_ms in state_periods:
        state_hz = 1000.0 / state_ms
        for health_ms in health_periods:
            if health_ms < state_ms:
                continue
            health_hz = 1000.0 / health_ms
            tx_kbit_s = target_bits * cmd_hz / 1000.0
            rx_kbit_s = (
                state_bits * state_hz / 1000.0 +
                health_bits * health_hz / 1000.0
            )
            total_kbit_s = tx_kbit_s + rx_kbit_s
            min_baud = int(
                total_kbit_s * 1000.0 * 100.0 /
                max_baud_util_pct + 0.999999
            )
            for baud in bauds:
                util_pct = total_kbit_s * 1000.0 * 100.0 / baud
                margin_pct = max_baud_util_pct - util_pct
                target_wire_ms = target_bits * 1000.0 / baud
                state_wire_ms = state_bits * 1000.0 / baud
                health_wire_ms = health_bits * 1000.0 / baud
                verdict = (
                    "PASS_STATIC"
                    if util_pct <= max_baud_util_pct else
                    "OVER_BUDGET"
                )
                rows.append(Row(
                    state_ms=state_ms,
                    health_ms=health_ms,
                    baud=baud,
                    state_hz=state_hz,
                    health_hz=health_hz,
                    tx_kbit_s=tx_kbit_s,
                    rx_kbit_s=rx_kbit_s,
                    total_kbit_s=total_kbit_s,
                    util_pct=util_pct,
                    margin_pct=margin_pct,
                    verdict=verdict,
                    min_baud=min_baud,
                    target_wire_ms=target_wire_ms,
                    state_wire_ms=state_wire_ms,
                    health_wire_ms=health_wire_ms,
                ))
    return rows


def best_passing_by_baud(rows: list[Row]) -> list[Row]:
    best: dict[int, Row] = {}
    for row in rows:
        if row.verdict != "PASS_STATIC":
            continue
        current = best.get(row.baud)
        # Prefer the fastest state telemetry, then fastest health telemetry,
        # then more residual margin.
        key = (-row.state_ms, -row.health_ms, row.margin_pct)
        current_key = (
            (-current.state_ms, -current.health_ms, current.margin_pct)
            if current is not None else None
        )
        if current is None or key > current_key:
            best[row.baud] = row
    return [best[baud] for baud in sorted(best)]


def smoke_env(row: Row) -> str:
    return (
        f"M2_MOTOR_BAUD={row.baud} "
        f"M2_MOTOR_STATE_PERIOD_MS={row.state_ms} "
        f"M2_MOTOR_HEALTH_PERIOD_MS={row.health_ms} "
        f"M2_MOTOR_REQUIRE_BUDGET_BAUDS={row.baud}"
    )


def profile_id(row: Row) -> str:
    return f"state{row.state_ms}_health{row.health_ms}_{row.baud}"


def risk(row: Row) -> str:
    if row.verdict != "PASS_STATIC":
        return "over_budget"
    if row.margin_pct < 1.0:
        return "thin_margin"
    return "static_margin"


def adoption(row: Row) -> str:
    if row.verdict != "PASS_STATIC":
        if row.state_ms == 20 and row.health_ms == 200 and row.baud == 921600:
            return "comparison_only"
        return "reject"
    if row.state_ms == 20 and row.health_ms == 200 and row.baud == 2_000_000:
        return "first_smoke"
    if row.baud == 921600:
        return "low_telemetry_candidate"
    return "comparison_pass"


def print_rows(rows: list[Row]) -> None:
    headers = [
        "profile id",
        "state ms",
        "health ms",
        "state Hz",
        "health Hz",
        "baud",
        "tx kbit/s",
        "rx kbit/s",
        "total kbit/s",
        "baud util %",
        "margin %",
        "min baud",
        "target wire ms",
        "state wire ms",
        "health wire ms",
        "target+state wire ms",
        "verdict",
        "risk",
        "adoption",
        "smoke env",
    ]
    aligns = [
        "---",
        "---:",
        "---:",
        "---:",
        "---:",
        "---:",
        "---:",
        "---:",
        "---:",
        "---:",
        "---:",
        "---:",
        "---:",
        "---:",
        "---:",
        "---:",
        "---",
        "---",
        "---",
        "---",
    ]
    print("| " + " | ".join(headers) + " |")
    print("|" + "|".join(aligns) + "|")
    for row in rows:
        print(
            "| "
            + " | ".join([
                profile_id(row),
                str(row.state_ms),
                str(row.health_ms),
                fmt(row.state_hz),
                fmt(row.health_hz),
                str(row.baud),
                fmt(row.tx_kbit_s),
                fmt(row.rx_kbit_s),
                fmt(row.total_kbit_s),
                fmt(row.util_pct),
                fmt(row.margin_pct),
                str(row.min_baud),
                fmt(row.target_wire_ms, 3),
                fmt(row.state_wire_ms, 3),
                fmt(row.health_wire_ms, 3),
                fmt(row.target_wire_ms + row.state_wire_ms, 3),
                row.verdict,
                risk(row),
                adoption(row),
                f"`{smoke_env(row)}`",
            ])
            + " |"
        )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Sweep M2 JointState/MotorHealth publish periods against the "
            "static motor-m2 UART budget."
        )
    )
    parser.add_argument("--cmd-hz", type=float, default=200.0)
    parser.add_argument(
        "--state-period-ms",
        type=parse_state_periods,
        default=parse_state_periods(STATE_PERIOD_DEFAULT),
        help=f"State periods to sweep. Default: {STATE_PERIOD_DEFAULT}.",
    )
    parser.add_argument(
        "--health-period-ms",
        type=parse_health_periods,
        default=parse_health_periods(HEALTH_PERIOD_DEFAULT),
        help=f"Health periods to sweep. Default: {HEALTH_PERIOD_DEFAULT}.",
    )
    parser.add_argument(
        "--baud",
        type=parse_bauds,
        default=parse_bauds(BAUD_DEFAULT),
        help=f"Bauds to sweep. Default: {BAUD_DEFAULT}.",
    )
    parser.add_argument("--max-baud-util-pct", type=float, default=30.0)
    parser.add_argument(
        "--xrce-overhead-bytes",
        type=float,
        default=wire_budget.MOTOR_M2_DEFAULT_XRCE_OVERHEAD_BYTES,
    )
    parser.add_argument(
        "--pass-only",
        action="store_true",
        help="Only print rows that pass the static budget.",
    )
    args = parser.parse_args()

    if not math.isfinite(args.cmd_hz):
        raise SystemExit("ERROR: --cmd-hz must be finite")
    if args.cmd_hz <= 0:
        raise SystemExit("ERROR: --cmd-hz must be > 0")
    if not math.isfinite(args.max_baud_util_pct):
        raise SystemExit("ERROR: --max-baud-util-pct must be finite")
    if args.max_baud_util_pct <= 0:
        raise SystemExit("ERROR: --max-baud-util-pct must be > 0")
    if not math.isfinite(args.xrce_overhead_bytes):
        raise SystemExit("ERROR: --xrce-overhead-bytes must be finite")
    if args.xrce_overhead_bytes < 0:
        raise SystemExit("ERROR: --xrce-overhead-bytes must be >= 0")

    state_periods = sorted(set(args.state_period_ms))
    health_periods = sorted(set(args.health_period_ms))
    bauds = sorted(set(args.baud))
    rows = project_rows(
        cmd_hz=args.cmd_hz,
        state_periods=state_periods,
        health_periods=health_periods,
        bauds=bauds,
        max_baud_util_pct=args.max_baud_util_pct,
        xrce_overhead_bytes=args.xrce_overhead_bytes,
    )
    if not rows:
        raise SystemExit(
            "ERROR: no valid period combinations after applying "
            "health period >= state period"
        )
    rows.sort(key=lambda row: (row.baud, row.state_ms, row.health_ms))
    output_rows = [row for row in rows if row.verdict == "PASS_STATIC"] if args.pass_only else rows
    best_rows = best_passing_by_baud(rows)

    print("# M2 Motor Telemetry Period Sweep")
    print()
    print("- source: static CDR field-size estimate from `tools/com-wire-budget.py`")
    print(f"- target command rate: {fmt(args.cmd_hz)} Hz")
    print(f"- budget contract: baud_util_pct <= {fmt(args.max_baud_util_pct)}")
    print(
        "- period guard: state "
        f"{STATE_PERIOD_MIN_MS}..{STATE_PERIOD_MAX_MS}ms, "
        f"health {HEALTH_PERIOD_MIN_MS}..{HEALTH_PERIOD_MAX_MS}ms, "
        "health period >= state period"
    )
    print("- note: this is static UART planning only; it does not replace Agent smoke evidence")
    print()
    print("## Fastest Passing Telemetry Per Baud")
    print()
    if best_rows:
        print_rows(best_rows)
    else:
        print("No passing rows for the selected sweep.")
    print()
    print("## Sweep Rows")
    print()
    print_rows(output_rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
