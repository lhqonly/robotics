#!/usr/bin/env python3
"""Estimate serial utilization for command/status communication profiles."""

import argparse
from pathlib import Path


def parse_float_list(raw: str) -> list[float]:
    values: list[float] = []
    for item in raw.replace(",", " ").split():
        try:
            values.append(float(item))
        except ValueError as exc:
            raise argparse.ArgumentTypeError(
                f"expected number list, got {raw!r}"
            ) from exc
    if not values:
        raise argparse.ArgumentTypeError("expected at least one number")
    return values


def parse_int_list(raw: str) -> list[int]:
    values: list[int] = []
    for item in raw.replace(",", " ").split():
        try:
            values.append(int(item))
        except ValueError as exc:
            raise argparse.ArgumentTypeError(
                f"expected integer list, got {raw!r}"
            ) from exc
    if not values:
        raise argparse.ArgumentTypeError("expected at least one integer")
    return values


def parse_metrics(path: Path) -> dict[str, float]:
    metrics: dict[str, float] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("METRICS "):
            continue
        for item in line.split()[1:]:
            if "=" not in item:
                continue
            key, value = item.split("=", 1)
            try:
                metrics[key] = float(value.rstrip("%"))
            except ValueError:
                pass
    if not metrics:
        raise SystemExit(f"ERROR: no METRICS line found in {path}")
    return metrics


def fmt(value: float, digits: int = 2) -> str:
    return f"{value:.{digits}f}"


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Project UART 8N1 utilization from an agent-wire-stats .wire.log. "
            "This is a planning estimate, not a replacement for hardware runs."
        )
    )
    parser.add_argument("--wire-log", type=Path, help="agent-wire-stats .wire.log")
    parser.add_argument("--baseline-cmd-hz", type=float, default=20.0)
    parser.add_argument("--baseline-status-hz", type=float, default=20.0)
    parser.add_argument("--tx-kbit-s", type=float, help="agent->MCU serial kbit/s")
    parser.add_argument("--rx-kbit-s", type=float, help="MCU->agent serial kbit/s")
    parser.add_argument(
        "--cmd-hz",
        type=parse_float_list,
        default=parse_float_list("200"),
        help="Target command rates, comma/space separated. Default: 200.",
    )
    parser.add_argument(
        "--status-every-n",
        type=parse_int_list,
        default=parse_int_list("40"),
        help="Status decimation factors, comma/space separated. Default: 40.",
    )
    parser.add_argument(
        "--baud",
        type=parse_float_list,
        default=parse_float_list("921600"),
        help="UART baud rates, comma/space separated. Default: 921600.",
    )
    parser.add_argument(
        "--max-baud-util-pct",
        type=float,
        help=(
            "Optional contract threshold for projected UART utilization. "
            "When set, the table includes a verdict column."
        ),
    )
    parser.add_argument(
        "--fail-on-over-budget",
        action="store_true",
        help="Exit non-zero if any projected row exceeds --max-baud-util-pct.",
    )
    args = parser.parse_args()

    tx_kbit_s = args.tx_kbit_s
    rx_kbit_s = args.rx_kbit_s
    total_kbit_s = None
    source = "manual"

    if args.wire_log:
        metrics = parse_metrics(args.wire_log)
        tx_kbit_s = metrics.get("tx_serial_kbit_s", tx_kbit_s)
        rx_kbit_s = metrics.get("rx_serial_kbit_s", rx_kbit_s)
        total_kbit_s = metrics.get("total_serial_kbit_s")
        source = str(args.wire_log)

    if tx_kbit_s is None or rx_kbit_s is None:
        raise SystemExit(
            "ERROR: provide --wire-log or both --tx-kbit-s and --rx-kbit-s"
        )
    if args.baseline_cmd_hz <= 0 or args.baseline_status_hz <= 0:
        raise SystemExit("ERROR: baseline rates must be > 0")
    if any(cmd_hz <= 0 for cmd_hz in args.cmd_hz) or \
            any(status_every_n < 1 for status_every_n in args.status_every_n) or \
            any(baud <= 0 for baud in args.baud):
        raise SystemExit("ERROR: cmd-hz/baud must be > 0 and status-every-n >= 1")
    if args.max_baud_util_pct is not None and args.max_baud_util_pct <= 0:
        raise SystemExit("ERROR: --max-baud-util-pct must be > 0")
    if args.fail_on_over_budget and args.max_baud_util_pct is None:
        raise SystemExit(
            "ERROR: --fail-on-over-budget requires --max-baud-util-pct"
        )

    tx_bits_per_cmd = tx_kbit_s * 1000.0 / args.baseline_cmd_hz
    rx_bits_per_status = rx_kbit_s * 1000.0 / args.baseline_status_hz

    print("# Communication Wire Budget Estimate")
    print()
    print(f"- source: `{source}`")
    if total_kbit_s is not None:
        print(f"- observed total: {fmt(total_kbit_s)} kbit/s")
    print(
        "- baseline: "
        f"cmd={fmt(args.baseline_cmd_hz)}Hz, "
        f"status={fmt(args.baseline_status_hz)}Hz, "
        f"tx={fmt(tx_kbit_s)} kbit/s, rx={fmt(rx_kbit_s)} kbit/s"
    )
    print(
        "- per sample estimate: "
        f"cmd={fmt(tx_bits_per_cmd, 1)} serial bits, "
        f"status={fmt(rx_bits_per_status, 1)} serial bits"
    )
    if args.max_baud_util_pct is not None:
        print(f"- budget contract: baud_util_pct <= {fmt(args.max_baud_util_pct)}")
    print()

    headers = [
        "cmd Hz",
        "status every N",
        "status Hz",
        "baud",
        "tx kbit/s",
        "rx kbit/s",
        "total kbit/s",
        "baud util %",
    ]
    aligns = ["---:"] * len(headers)
    if args.max_baud_util_pct is not None:
        headers.append("verdict")
        aligns.append("---")
    print("| " + " | ".join(headers) + " |")
    print("|" + "|".join(aligns) + "|")
    over_budget = False
    for cmd_hz in args.cmd_hz:
        for status_every_n in args.status_every_n:
            projected_status_hz = cmd_hz / status_every_n
            projected_tx_kbit_s = tx_bits_per_cmd * cmd_hz / 1000.0
            projected_rx_kbit_s = (
                rx_bits_per_status * projected_status_hz / 1000.0
            )
            projected_total_kbit_s = projected_tx_kbit_s + projected_rx_kbit_s
            for baud in args.baud:
                projected_util = projected_total_kbit_s * 1000.0 * 100.0 / baud
                row = [
                    fmt(cmd_hz),
                    str(status_every_n),
                    fmt(projected_status_hz),
                    str(int(baud)),
                    fmt(projected_tx_kbit_s),
                    fmt(projected_rx_kbit_s),
                    fmt(projected_total_kbit_s),
                    fmt(projected_util),
                ]
                if args.max_baud_util_pct is not None:
                    if projected_util <= args.max_baud_util_pct:
                        row.append("PASS")
                    else:
                        row.append("OVER_BUDGET")
                        over_budget = True
                print("| " + " | ".join(row) + " |")
    print()
    print(
        "Note: this linear model uses measured XRCE serial bytes from one profile. "
        "Discovery traffic, reliable retries, Agent verbosity overhead, OS jitter, "
        "and MCU scheduling are not modeled."
    )
    if over_budget and args.fail_on_over_budget:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
