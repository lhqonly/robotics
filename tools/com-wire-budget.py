#!/usr/bin/env python3
"""Estimate serial utilization for command/status communication profiles."""

import argparse
from pathlib import Path


MOTOR_M2_FRAME_ID_BYTES = 0
MOTOR_M2_DEFAULT_STATE_HZ = "50"
MOTOR_M2_DEFAULT_HEALTH_HZ = "5"
MOTOR_M2_DEFAULT_XRCE_OVERHEAD_BYTES = 32.0


def cdr_align(offset: int, size: int) -> int:
    return (size - (offset % size)) % size


def cdr_primitive(offset: int, size: int) -> int:
    return offset + cdr_align(offset, size) + size


def cdr_string(offset: int, content_bytes: int) -> int:
    # CDR strings carry a uint32 length plus a trailing NUL byte.
    return offset + cdr_align(offset, 4) + 4 + content_bytes + 1


def cdr_header_size(frame_id_bytes: int = MOTOR_M2_FRAME_ID_BYTES) -> int:
    offset = 0
    offset = cdr_primitive(offset, 4)  # builtin_interfaces/Time.sec
    offset = cdr_primitive(offset, 4)  # builtin_interfaces/Time.nanosec
    offset = cdr_string(offset, frame_id_bytes)
    return offset


def motor_m2_payload_sizes(frame_id_bytes: int = MOTOR_M2_FRAME_ID_BYTES) -> dict[str, int]:
    """Return CDR payload bytes for M2 motor messages with fixed-size fields."""
    header_size = cdr_header_size(frame_id_bytes)

    joint_target = header_size
    joint_target = cdr_primitive(joint_target, 4)  # seq
    joint_target = cdr_primitive(joint_target, 1)  # joint_id
    joint_target = cdr_primitive(joint_target, 1)  # control_mode
    for _ in range(9):
        joint_target = cdr_primitive(joint_target, 8)
    joint_target = cdr_primitive(joint_target, 4)  # ttl_us
    joint_target = cdr_primitive(joint_target, 4)  # flags

    joint_state = header_size
    joint_state = cdr_primitive(joint_state, 4)  # seq
    joint_state = cdr_primitive(joint_state, 1)  # joint_id
    joint_state = cdr_primitive(joint_state, 1)  # control_mode
    for _ in range(6):
        joint_state = cdr_primitive(joint_state, 8)
    for _ in range(4):
        joint_state = cdr_primitive(joint_state, 4)
    joint_state = cdr_primitive(joint_state, 1)  # target_fresh
    joint_state = cdr_primitive(joint_state, 1)  # enabled

    motor_health = header_size
    motor_health = cdr_primitive(motor_health, 1)  # bus_id
    motor_health = cdr_primitive(motor_health, 1)  # joint_count
    for _ in range(7):
        motor_health = cdr_primitive(motor_health, 8)
    for _ in range(2):
        motor_health = cdr_primitive(motor_health, 8)
    motor_health = cdr_primitive(motor_health, 1)  # reconciles

    return {
        "JointTarget": joint_target,
        "JointState": joint_state,
        "MotorHealth": motor_health,
    }


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


def flatten_float_lists(values: list[list[float]] | None,
                        default: str) -> list[float]:
    """Flatten repeated argparse list options, preserving legacy defaults."""
    if values is None:
        return parse_float_list(default)
    return [item for group in values for item in group]


def flatten_int_lists(values: list[list[int]] | None,
                      default: str) -> list[int]:
    """Flatten repeated argparse list options, preserving legacy defaults."""
    if values is None:
        return parse_int_list(default)
    return [item for group in values for item in group]


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


def budget_columns(projected_total_kbit_s: float,
                   projected_util: float,
                   max_baud_util_pct: float) -> tuple[str, str, str, bool]:
    min_baud = projected_total_kbit_s * 1000.0 * 100.0 / max_baud_util_pct
    budget_margin = max_baud_util_pct - projected_util
    if projected_util <= max_baud_util_pct:
        return str(int(min_baud + 0.999999)), fmt(budget_margin), "PASS", False
    return str(int(min_baud + 0.999999)), fmt(budget_margin), "OVER_BUDGET", True


def run_motor_m2_profile(args: argparse.Namespace,
                         cmd_hz_values: list[float],
                         baud_values: list[float]) -> int:
    state_hz_values = flatten_float_lists(
        args.motor_state_hz, MOTOR_M2_DEFAULT_STATE_HZ)
    health_hz_values = flatten_float_lists(
        args.motor_health_hz, MOTOR_M2_DEFAULT_HEALTH_HZ)
    if any(state_hz < 0 for state_hz in state_hz_values):
        raise SystemExit("ERROR: --motor-state-hz must be >= 0")
    if any(health_hz < 0 for health_hz in health_hz_values):
        raise SystemExit("ERROR: --motor-health-hz must be >= 0")
    if args.xrce_overhead_bytes < 0:
        raise SystemExit("ERROR: --xrce-overhead-bytes must be >= 0")

    payload = motor_m2_payload_sizes()
    serial_bytes = {
        name: payload_bytes + args.xrce_overhead_bytes
        for name, payload_bytes in payload.items()
    }
    target_bits = serial_bytes["JointTarget"] * 10.0
    state_bits = serial_bytes["JointState"] * 10.0
    health_bits = serial_bytes["MotorHealth"] * 10.0

    print("# M2 Motor Wire Budget Estimate")
    print()
    print("- source: static CDR field-size estimate")
    print("- profile: `/motor` topics with empty `std_msgs/Header.frame_id`")
    print(
        "- payload bytes: "
        f"JointTarget={payload['JointTarget']}, "
        f"JointState={payload['JointState']}, "
        f"MotorHealth={payload['MotorHealth']}"
    )
    print(
        "- serial bytes per sample: payload + "
        f"{fmt(args.xrce_overhead_bytes, 1)}B XRCE/framing allowance "
        "(8N1 = 10 serial bits/byte)"
    )
    if args.max_baud_util_pct is not None:
        print(
            "- budget math: min_baud = total_kbit/s * 1000 * 100 / "
            "max_baud_util_pct"
        )
        print(f"- budget contract: baud_util_pct <= {fmt(args.max_baud_util_pct)}")
    print()

    headers = [
        "target Hz",
        "state Hz",
        "health Hz",
        "baud",
        "tx kbit/s",
        "rx kbit/s",
        "total kbit/s",
        "baud util %",
    ]
    aligns = ["---:"] * len(headers)
    if args.show_wire_time:
        headers.extend([
            "target wire ms",
            "state wire ms",
            "health wire ms",
            "target+state wire ms",
        ])
        aligns.extend(["---:", "---:", "---:", "---:"])
    if args.max_baud_util_pct is not None:
        headers.append("min baud @ budget")
        aligns.append("---:")
        headers.append("budget margin %")
        aligns.append("---:")
        headers.append("verdict")
        aligns.append("---")
    print("| " + " | ".join(headers) + " |")
    print("|" + "|".join(aligns) + "|")

    over_budget = False
    worst: tuple[float, str] | None = None
    for target_hz in cmd_hz_values:
        for state_hz in state_hz_values:
            for health_hz in health_hz_values:
                projected_tx_kbit_s = target_bits * target_hz / 1000.0
                projected_rx_kbit_s = (
                    state_bits * state_hz / 1000.0 +
                    health_bits * health_hz / 1000.0
                )
                projected_total_kbit_s = (
                    projected_tx_kbit_s + projected_rx_kbit_s
                )
                for baud in baud_values:
                    projected_util = (
                        projected_total_kbit_s * 1000.0 * 100.0 / baud
                    )
                    row_label = (
                        f"target={fmt(target_hz)}Hz "
                        f"state={fmt(state_hz)}Hz "
                        f"health={fmt(health_hz)}Hz baud={int(baud)}"
                    )
                    if worst is None or projected_util > worst[0]:
                        worst = (projected_util, row_label)
                    row = [
                        fmt(target_hz),
                        fmt(state_hz),
                        fmt(health_hz),
                        str(int(baud)),
                        fmt(projected_tx_kbit_s),
                        fmt(projected_rx_kbit_s),
                        fmt(projected_total_kbit_s),
                        fmt(projected_util),
                    ]
                    if args.show_wire_time:
                        target_wire_ms = target_bits * 1000.0 / baud
                        state_wire_ms = state_bits * 1000.0 / baud
                        health_wire_ms = health_bits * 1000.0 / baud
                        row.extend([
                            fmt(target_wire_ms, 3),
                            fmt(state_wire_ms, 3),
                            fmt(health_wire_ms, 3),
                            fmt(target_wire_ms + state_wire_ms, 3),
                        ])
                    if args.max_baud_util_pct is not None:
                        min_baud, margin, verdict, is_over = budget_columns(
                            projected_total_kbit_s,
                            projected_util,
                            args.max_baud_util_pct,
                        )
                        row.extend([min_baud, margin, verdict])
                        over_budget = over_budget or is_over
                    print("| " + " | ".join(row) + " |")

    print()
    if worst is not None:
        print(
            "Motor suggestion: worst projected row is "
            f"{worst[1]} at {fmt(worst[0])}% baud utilization."
        )
    print(
        "Note: motor-m2 is a static CDR/framing estimate. It does not model "
        "XRCE discovery/create traffic, reliable retries, byte-stuffing, Agent "
        "verbosity overhead, MCU executor timing, or control-loop scheduling."
    )
    if args.show_wire_time:
        print(
            "Wire-time columns are UART serialization lower bounds for one "
            "motor sample. They do not include DDS/XRCE scheduling or MCU work."
        )
    if over_budget and args.fail_on_over_budget:
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Project UART 8N1 utilization from an agent-wire-stats .wire.log. "
            "This is a planning estimate, not a replacement for hardware runs."
        )
    )
    parser.add_argument(
        "--profile",
        choices=("com-observed", "motor-m2"),
        default="com-observed",
        help=(
            "Budget model to run. com-observed uses measured /com wire logs; "
            "motor-m2 estimates M2 /motor topics statically."
        ),
    )
    parser.add_argument("--wire-log", type=Path, help="agent-wire-stats .wire.log")
    parser.add_argument("--baseline-cmd-hz", type=float, default=20.0)
    parser.add_argument("--baseline-status-hz", type=float, default=20.0)
    parser.add_argument("--tx-kbit-s", type=float, help="agent->MCU serial kbit/s")
    parser.add_argument("--rx-kbit-s", type=float, help="MCU->agent serial kbit/s")
    parser.add_argument(
        "--cmd-hz",
        type=parse_float_list,
        action="append",
        default=None,
        help=(
            "Target command rates, comma/space separated. May be repeated. "
            "Default: 200."
        ),
    )
    parser.add_argument(
        "--status-every-n",
        "--status-every",
        dest="status_every_n",
        type=parse_int_list,
        action="append",
        default=None,
        help=(
            "Status decimation factors, comma/space separated. May be "
            "repeated. Default: 40."
        ),
    )
    parser.add_argument(
        "--baud",
        type=parse_float_list,
        action="append",
        default=None,
        help=(
            "UART baud rates, comma/space separated. May be repeated. "
            "Default: 921600."
        ),
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
    parser.add_argument(
        "--show-wire-time",
        action="store_true",
        help=(
            "Include per-message UART serialization time estimates. These are "
            "wire-time lower bounds only, not end-to-end ROS/XRCE latency."
        ),
    )
    parser.add_argument(
        "--motor-state-hz",
        type=parse_float_list,
        action="append",
        default=None,
        help=(
            "motor-m2 only: JointState publish rates, comma/space separated. "
            f"Default: {MOTOR_M2_DEFAULT_STATE_HZ}."
        ),
    )
    parser.add_argument(
        "--motor-health-hz",
        type=parse_float_list,
        action="append",
        default=None,
        help=(
            "motor-m2 only: MotorHealth publish rates, comma/space separated. "
            f"Default: {MOTOR_M2_DEFAULT_HEALTH_HZ}."
        ),
    )
    parser.add_argument(
        "--xrce-overhead-bytes",
        type=float,
        default=MOTOR_M2_DEFAULT_XRCE_OVERHEAD_BYTES,
        help=(
            "motor-m2 only: conservative per-sample XRCE/framing byte allowance "
            "added to each CDR payload. Default: 32."
        ),
    )
    args = parser.parse_args()
    cmd_hz_values = flatten_float_lists(args.cmd_hz, "200")
    status_every_n_values = flatten_int_lists(args.status_every_n, "40")
    baud_values = flatten_float_lists(args.baud, "921600")

    if args.baseline_cmd_hz <= 0 or args.baseline_status_hz <= 0:
        raise SystemExit("ERROR: baseline rates must be > 0")
    invalid_cmd_hz = any(cmd_hz <= 0 for cmd_hz in cmd_hz_values)
    invalid_status_every = any(
        status_every_n < 1 for status_every_n in status_every_n_values)
    invalid_baud = any(baud <= 0 for baud in baud_values)
    if invalid_cmd_hz or invalid_status_every or invalid_baud:
        raise SystemExit("ERROR: cmd-hz/baud must be > 0 and status-every-n >= 1")
    if args.max_baud_util_pct is not None and args.max_baud_util_pct <= 0:
        raise SystemExit("ERROR: --max-baud-util-pct must be > 0")
    if args.fail_on_over_budget and args.max_baud_util_pct is None:
        raise SystemExit(
            "ERROR: --fail-on-over-budget requires --max-baud-util-pct"
        )
    if args.profile == "motor-m2":
        return run_motor_m2_profile(
            args, cmd_hz_values, baud_values)

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
        print(
            "- budget math: min_baud = total_kbit/s * 1000 * 100 / "
            "max_baud_util_pct"
        )
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
    if args.show_wire_time:
        headers.extend([
            "cmd wire ms",
            "status wire ms",
            "full echo wire ms",
        ])
        aligns.extend(["---:", "---:", "---:"])
    if args.max_baud_util_pct is not None:
        headers.append("min baud @ budget")
        aligns.append("---:")
        headers.append("budget margin %")
        aligns.append("---:")
        headers.append("verdict")
        aligns.append("---")
    print("| " + " | ".join(headers) + " |")
    print("|" + "|".join(aligns) + "|")
    over_budget = False
    for cmd_hz in cmd_hz_values:
        for status_every_n in status_every_n_values:
            projected_status_hz = cmd_hz / status_every_n
            projected_tx_kbit_s = tx_bits_per_cmd * cmd_hz / 1000.0
            projected_rx_kbit_s = (
                rx_bits_per_status * projected_status_hz / 1000.0
            )
            projected_total_kbit_s = projected_tx_kbit_s + projected_rx_kbit_s
            for baud in baud_values:
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
                if args.show_wire_time:
                    cmd_wire_ms = tx_bits_per_cmd * 1000.0 / baud
                    status_wire_ms = rx_bits_per_status * 1000.0 / baud
                    row.extend([
                        fmt(cmd_wire_ms, 3),
                        fmt(status_wire_ms, 3),
                        fmt(cmd_wire_ms + status_wire_ms, 3),
                    ])
                if args.max_baud_util_pct is not None:
                    min_baud, margin, verdict, is_over = budget_columns(
                        projected_total_kbit_s,
                        projected_util,
                        args.max_baud_util_pct,
                    )
                    row.extend([min_baud, margin, verdict])
                    over_budget = over_budget or is_over
                print("| " + " | ".join(row) + " |")
    print()
    print(
        "Note: this linear model uses measured XRCE serial bytes from one profile. "
        "Discovery traffic, reliable retries, Agent verbosity overhead, OS jitter, "
        "and MCU scheduling are not modeled."
    )
    if args.show_wire_time:
        print(
            "Wire-time columns are UART serialization lower bounds for one command "
            "frame, one status frame, and their sum. They do not include executor, "
            "DDS/XRCE, OS scheduling, MCU spin/read timeout, or control-loop time."
        )
    if over_budget and args.fail_on_over_budget:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
