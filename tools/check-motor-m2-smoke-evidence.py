#!/usr/bin/env python3
"""Check manually captured M2 motor micro-ROS smoke evidence.

The input is a small KEY=value file. It is intentionally simpler than parsing
raw ROS YAML so that a hardware run can copy the relevant fields without making
the checker depend on live ROS tooling.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


TEMPLATE = """# M2 motor smoke evidence.
# Fill this file from the commands printed by tools/recommend-motor-m2-smoke-command.sh.
sample_only=true
template_generated=true
evidence_source=template
evidence_capture_id=template
swd_status=ok
firmware_build=ok
firmware_flash=ok
agent_connected=ok
topic_motor_target=present
topic_motor_state=present
topic_motor_health=present
topic_com_status=present
info_motor_target=ok
info_motor_state=ok
info_motor_health=ok
info_com_status=ok

# Positive disabled target, seq=42.
reject_baseline_target_enabled=false
state_before_accept_seq=0
state_after_accept_seq=1
state_after_accept_last_target_seq=42
health_before_reject_targets_received=1
health_before_reject_targets_applied=0

# Negative non-empty frame_id target, seq=43.
state_after_reject_seq=2
state_after_reject_last_target_seq=42
health_after_reject_targets_received=1
health_after_reject_targets_applied=0

# Legal target after reject, seq=44.
state_after_legal_seq=3
state_after_legal_last_target_seq=44

# Clamp/fault target, seq=45. MOTOR_FAULT_LIMIT_CLAMPED is bit 2, value 4.
state_after_clamp_seq=4
state_after_clamp_last_target_seq=45
state_after_clamp_fault_bits=4
state_after_clamp_sample_age_us=1000
clamp_target_ttl_us=100000

# TTL stale evidence after waiting longer than ttl_us. MOTOR_FAULT_STALE_TARGET is bit 1, value 2.
state_after_ttl_seq=5
state_after_ttl_last_target_seq=45
state_after_ttl_target_fresh=false
state_after_ttl_enabled=false
state_after_ttl_fault_bits=2
health_before_ttl_stale_targets=0
health_after_ttl_stale_targets=1

# Topic rates from ros2 topic hz.
motor_state_hz=50.0
motor_health_hz=5.0
com_status_hz=5.0

# Enabled 200Hz target soak. This is separate from the disabled seq42/43/44
# frame_id negative-test sequence above.
enabled_soak_target_hz=200.0
enabled_soak_targets_sent=400
enabled_soak_first_target_seq=1000
enabled_soak_last_target_seq=1399
enabled_soak_state_last_target_seq=1399
enabled_soak_state_target_fresh=true
enabled_soak_state_enabled=true
enabled_soak_state_fault_bits=0
enabled_soak_targets_received_before=2
enabled_soak_targets_received_mid=202
enabled_soak_targets_received_after=402
enabled_soak_targets_applied_before=0
enabled_soak_targets_applied_mid=8000
enabled_soak_targets_applied_after=16000
com_status_soak_hz=5.0

# Motor-enabled runtime memory evidence.
microros_stack_free_words=128
newlib_heap_free_before_msp_reserve_bytes=1024
newlib_heap_msp_reserved_bytes=1024
agent_session_loss_events=0
hardfault_seen=false
"""


TRUTHY = {"1", "true", "yes", "ok", "present", "pass", "connected"}
FALSY = {"0", "false", "no", "missing", "fail", "failed", "absent", "none"}


def read_evidence(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"line {lineno}: expected KEY=value")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            raise ValueError(f"line {lineno}: empty key")
        if key in values:
            raise ValueError(f"line {lineno}: duplicate key {key}")
        values[key] = value
    return values


def scalar_from_text(text: str, key: str) -> str | None:
    prefix = f"{key}:"
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith(prefix):
            return line[len(prefix):].strip().strip("'\"")
    return None


def count_from_topic_info(text: str, key: str) -> int | None:
    raw = scalar_from_text(text, key)
    if raw is None:
        return None
    return as_int(raw)


def topic_type_from_info(text: str) -> str:
    return scalar_from_text(text, "Type") or ""


def average_rate_from_text(text: str) -> str | None:
    rate: str | None = None
    for raw in text.splitlines():
        match = re.search(r"average rate:\s*([0-9]+(?:\.[0-9]+)?)", raw)
        if match:
            rate = match.group(1)
    return rate


def microros_stack_free_words_from_text(text: str) -> str | None:
    for raw in text.splitlines():
        line = raw.strip()
        if not line.startswith("microros_task_stack"):
            continue
        match = re.search(r"\bhwm_free_words=(\d+)\b", line)
        if match:
            return match.group(1)
        match = re.search(r"\bfree=(\d+)\s+words\b", line)
        if match:
            return match.group(1)
    return None


def newlib_heap_metric_from_text(text: str, key: str) -> str | None:
    for raw in text.splitlines():
        line = raw.strip()
        if not line.startswith("newlib_heap "):
            continue
        match = re.search(rf"\b{re.escape(key)}=(\d+)\b", line)
        if match:
            return match.group(1)
    return None


def agent_session_loss_events_from_text(text: str) -> str | None:
    if not text:
        return None
    pattern = re.compile(
        r"session.*(lost|closed|reset)|connection.*lost|disconnect",
        re.IGNORECASE,
    )
    return str(sum(1 for line in text.splitlines() if pattern.search(line)))


def hardfault_seen_from_text(text: str) -> str | None:
    if not text:
        return None
    return "true" if re.search(r"hardfault|!!HARDFAULT!!", text, re.IGNORECASE) else "false"


def read_text_if_exists(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8")


def key_values_from_text(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key:
            values[key] = value
    return values


def read_evidence_dir(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    env = path / "evidence.env"
    if env.exists():
        values.update(read_evidence(env))
    values["_evidence_path_kind"] = "directory"
    values["template_generated"] = "false"
    values["evidence_source"] = "directory_raw_capture"
    values["evidence_capture_id"] = "directory_raw_capture"

    topics = {
        line.strip()
        for line in read_text_if_exists(path / "topics.txt").splitlines()
        if line.strip()
    }
    topic_map = {
        "topic_motor_target": "/motor/tp_joint_target",
        "topic_motor_state": "/motor/tp_joint_state",
        "topic_motor_health": "/motor/tp_motor_health",
        "topic_com_status": "/com/tp_mcu_status",
    }
    for key, topic in topic_map.items():
        values[key] = "present" if topic in topics else "missing"

    info_specs = {
        "info_motor_target": (
            path / "info.motor_target.txt",
            "exo_motor_msgs/msg/JointTarget",
            "Subscription count",
        ),
        "info_motor_state": (
            path / "info.motor_state.txt",
            "exo_motor_msgs/msg/JointState",
            "Publisher count",
        ),
        "info_motor_health": (
            path / "info.motor_health.txt",
            "exo_motor_msgs/msg/MotorHealth",
            "Publisher count",
        ),
        "info_com_status": (
            path / "info.com_status.txt",
            "",
            "Publisher count",
        ),
    }
    for key, (info_path, expected_type, count_key) in info_specs.items():
        text = read_text_if_exists(info_path)
        topic_type = topic_type_from_info(text)
        count = count_from_topic_info(text, count_key)
        type_ok = not expected_type or topic_type == expected_type
        count_ok = count is not None and count >= 1
        values[key] = "ok" if type_ok and count_ok else "missing"

    scalar_files = {
        "state.after_seq42.yaml": {
            "seq": "state_after_accept_seq",
            "last_target_seq": "state_after_accept_last_target_seq",
        },
        "health.before_reject.yaml": {
            "targets_received": "health_before_reject_targets_received",
            "targets_applied": "health_before_reject_targets_applied",
        },
        "state.after_reject_seq43.yaml": {
            "seq": "state_after_reject_seq",
            "last_target_seq": "state_after_reject_last_target_seq",
        },
        "health.after_reject_seq43.yaml": {
            "targets_received": "health_after_reject_targets_received",
            "targets_applied": "health_after_reject_targets_applied",
        },
        "state.after_seq44.yaml": {
            "seq": "state_after_legal_seq",
            "last_target_seq": "state_after_legal_last_target_seq",
        },
        "state.after_clamp_seq45.yaml": {
            "seq": "state_after_clamp_seq",
            "last_target_seq": "state_after_clamp_last_target_seq",
            "fault_bits": "state_after_clamp_fault_bits",
            "sample_age_us": "state_after_clamp_sample_age_us",
        },
        "state.after_ttl.yaml": {
            "seq": "state_after_ttl_seq",
            "last_target_seq": "state_after_ttl_last_target_seq",
            "target_fresh": "state_after_ttl_target_fresh",
            "enabled": "state_after_ttl_enabled",
            "fault_bits": "state_after_ttl_fault_bits",
        },
        "state.before_seq42.yaml": {
            "seq": "state_before_accept_seq",
        },
        "health.before_ttl.yaml": {
            "stale_targets": "health_before_ttl_stale_targets",
        },
        "health.after_ttl.yaml": {
            "stale_targets": "health_after_ttl_stale_targets",
        },
        "health.before_enabled_soak.yaml": {
            "targets_received": "enabled_soak_targets_received_before",
            "targets_applied": "enabled_soak_targets_applied_before",
        },
        "state.after_enabled_soak.yaml": {
            "last_target_seq": "enabled_soak_state_last_target_seq",
            "target_fresh": "enabled_soak_state_target_fresh",
            "enabled": "enabled_soak_state_enabled",
            "fault_bits": "enabled_soak_state_fault_bits",
        },
        "health.mid_enabled_soak.yaml": {
            "targets_received": "enabled_soak_targets_received_mid",
            "targets_applied": "enabled_soak_targets_applied_mid",
        },
        "health.after_enabled_soak.yaml": {
            "targets_received": "enabled_soak_targets_received_after",
            "targets_applied": "enabled_soak_targets_applied_after",
        },
    }
    for filename, mapping in scalar_files.items():
        text = read_text_if_exists(path / filename)
        for source_key, dest_key in mapping.items():
            value = scalar_from_text(text, source_key)
            if value is not None:
                values[dest_key] = value
            else:
                values.pop(dest_key, None)

    derived_files = {
        "motor_state_hz": (path / "rate.motor_state.txt", average_rate_from_text),
        "motor_health_hz": (path / "rate.motor_health.txt", average_rate_from_text),
        "com_status_hz": (path / "rate.com_status.txt", average_rate_from_text),
        "com_status_soak_hz": (
            path / "rate.com_status.soak.txt",
            average_rate_from_text,
        ),
        "microros_stack_free_words": (
            path / "stack-hwm.txt",
            microros_stack_free_words_from_text,
        ),
        "newlib_heap_free_before_msp_reserve_bytes": (
            path / "stack-hwm.txt",
            lambda text: newlib_heap_metric_from_text(
                text, "free_before_msp_reserve_bytes"
            ),
        ),
        "newlib_heap_msp_reserved_bytes": (
            path / "stack-hwm.txt",
            lambda text: newlib_heap_metric_from_text(text, "msp_reserved_bytes"),
        ),
        "agent_session_loss_events": (
            path / "agent.log",
            agent_session_loss_events_from_text,
        ),
        "hardfault_seen": (
            path / "agent.log",
            hardfault_seen_from_text,
        ),
    }
    for key, (source_path, parser) in derived_files.items():
        value = parser(read_text_if_exists(source_path))
        if value is not None:
            values[key] = value
        else:
            values.pop(key, None)

    for key, value in key_values_from_text(
        read_text_if_exists(path / "enabled_soak.summary.txt")
    ).items():
        values[key] = value

    return values


def as_bool(raw: str) -> bool | None:
    lowered = raw.strip().lower()
    if lowered in TRUTHY:
        return True
    if lowered in FALSY:
        return False
    return None


def as_float(raw: str) -> float | None:
    try:
        return float(raw)
    except ValueError:
        return None


def as_int(raw: str) -> int | None:
    try:
        return int(raw, 0)
    except ValueError:
        return None


class Checker:
    def __init__(self, values: dict[str, str]) -> None:
        self.values = values
        self.reasons: list[str] = []
        self.hardware_offline = False
        self.missing_evidence = False

    def value(self, key: str) -> str | None:
        return self.values.get(key)

    def reason(self, reason: str) -> None:
        self.reasons.append(reason)
        if (
            reason.startswith("missing_")
            or reason == "sample_template_not_filled"
            or reason == "file_evidence_not_raw_capture_use_directory"
            or reason == "template_generated_evidence_not_raw_capture"
        ):
            self.missing_evidence = True

    def require_bool(self, key: str) -> bool | None:
        raw = self.value(key)
        if raw is None:
            self.reason(f"missing_{key}")
            return None
        value = as_bool(raw)
        if value is None:
            self.reason(f"invalid_{key}")
        return value

    def require_true(self, key: str) -> None:
        value = self.require_bool(key)
        if value is False:
            self.reason(f"{key}_not_ok")

    def require_int(self, key: str) -> int | None:
        raw = self.value(key)
        if raw is None:
            self.reason(f"missing_{key}")
            return None
        value = as_int(raw)
        if value is None:
            self.reason(f"invalid_{key}")
        return value

    def require_float(self, key: str) -> float | None:
        raw = self.value(key)
        if raw is None:
            self.reason(f"missing_{key}")
            return None
        value = as_float(raw)
        if value is None:
            self.reason(f"invalid_{key}")
        return value

    def require_equal_int(self, key: str, expected: int) -> None:
        value = self.require_int(key)
        if value is not None and value != expected:
            self.reason(f"{key}_expected_{expected}_got_{value}")

    def require_same_int(self, before_key: str, after_key: str) -> None:
        before = self.require_int(before_key)
        after = self.require_int(after_key)
        if before is not None and after is not None and before != after:
            self.reason(f"{after_key}_changed_from_{before}_to_{after}")

    def require_greater_int(self, after_key: str, before_key: str) -> None:
        before = self.require_int(before_key)
        after = self.require_int(after_key)
        if before is not None and after is not None and after <= before:
            self.reason(f"{after_key}_not_after_{before_key}_{after}_le_{before}")

    def require_bit(self, key: str, bit_mask: int) -> None:
        value = self.require_int(key)
        if value is not None and (value & bit_mask) == 0:
            self.reason(f"{key}_missing_bit_{bit_mask}")

    def require_rate(self, key: str, minimum: float, maximum: float) -> None:
        value = self.require_float(key)
        if value is not None and not (minimum <= value <= maximum):
            self.reason(f"{key}_out_of_range_{minimum:g}_{maximum:g}_got_{value:g}")

    def require_lte_int(self, key: str, limit_key: str) -> None:
        value = self.require_int(key)
        limit = self.require_int(limit_key)
        if value is not None and limit is not None and value > limit:
            self.reason(f"{key}_gt_{limit_key}_{value}_gt_{limit}")

    def require_enabled_soak(self, args: argparse.Namespace) -> None:
        target_hz = self.require_float("enabled_soak_target_hz")
        if target_hz is not None and not (
            args.min_enabled_soak_target_hz
            <= target_hz
            <= args.max_enabled_soak_target_hz
        ):
            self.reason(
                "enabled_soak_target_hz_out_of_range_"
                f"{args.min_enabled_soak_target_hz:g}_"
                f"{args.max_enabled_soak_target_hz:g}_got_{target_hz:g}"
            )

        sent = self.require_int("enabled_soak_targets_sent")
        first_seq = self.require_int("enabled_soak_first_target_seq")
        last_seq = self.require_int("enabled_soak_last_target_seq")
        state_last_seq = self.require_int("enabled_soak_state_last_target_seq")
        received_before = self.require_int("enabled_soak_targets_received_before")
        received_mid = self.require_int("enabled_soak_targets_received_mid")
        received_after = self.require_int("enabled_soak_targets_received_after")
        applied_before = self.require_int("enabled_soak_targets_applied_before")
        applied_mid = self.require_int("enabled_soak_targets_applied_mid")
        applied_after = self.require_int("enabled_soak_targets_applied_after")
        target_fresh = self.require_bool("enabled_soak_state_target_fresh")
        state_enabled = self.require_bool("enabled_soak_state_enabled")
        fault_bits = self.require_int("enabled_soak_state_fault_bits")

        if sent is not None and sent < args.min_enabled_soak_targets_sent:
            self.reason(
                "enabled_soak_targets_sent_low_"
                f"{sent}_lt_{args.min_enabled_soak_targets_sent}"
            )
        if first_seq is not None and last_seq is not None and sent is not None:
            expected_last = first_seq + sent - 1
            if last_seq != expected_last:
                self.reason(
                    "enabled_soak_last_target_seq_expected_"
                    f"{expected_last}_got_{last_seq}"
                )
        if state_last_seq is not None and last_seq is not None:
            lag = last_seq - state_last_seq
            if lag < 0:
                self.reason(
                    "enabled_soak_state_last_target_seq_ahead_"
                    f"{state_last_seq}_gt_{last_seq}"
                )
            elif lag > args.max_enabled_soak_last_target_lag:
                self.reason(
                    "enabled_soak_state_last_target_seq_lag_"
                    f"{lag}_gt_{args.max_enabled_soak_last_target_lag}"
                )
        if target_fresh is False:
            self.reason("enabled_soak_state_target_not_fresh")
        if state_enabled is False:
            self.reason("enabled_soak_state_not_enabled")
        if fault_bits is not None and fault_bits != 0:
            self.reason(f"enabled_soak_state_fault_bits_expected_0_got_{fault_bits}")
        if (
            received_before is not None
            and received_mid is not None
            and received_after is not None
            and sent is not None
        ):
            received_delta = received_after - received_before
            min_received = int(sent * args.min_enabled_soak_received_ratio)
            if received_delta < min_received:
                self.reason(
                    "enabled_soak_targets_received_delta_low_"
                    f"{received_delta}_lt_{min_received}"
                )
            if not (received_before < received_mid < received_after):
                self.reason(
                    "enabled_soak_targets_received_not_monotonic_"
                    f"{received_before}_{received_mid}_{received_after}"
                )
        if (
            applied_before is not None
            and applied_mid is not None
            and applied_after is not None
        ):
            applied_delta = applied_after - applied_before
            min_applied = args.min_enabled_soak_applied_delta
            if received_before is not None and received_after is not None:
                received_delta = received_after - received_before
                min_applied = max(
                    min_applied,
                    int(received_delta * args.min_enabled_soak_applied_per_received),
                )
            if applied_delta < min_applied:
                self.reason(
                    "enabled_soak_targets_applied_delta_low_"
                    f"{applied_delta}_lt_{min_applied}"
                )
            if not (applied_before < applied_mid < applied_after):
                self.reason(
                    "enabled_soak_targets_applied_not_monotonic_"
                    f"{applied_before}_{applied_mid}_{applied_after}"
                )

    def check(self, args: argparse.Namespace) -> int:
        path_kind = self.value("_evidence_path_kind")
        if path_kind == "file":
            self.reason("file_evidence_not_raw_capture_use_directory")

        sample_only = self.value("sample_only")
        if sample_only is not None and as_bool(sample_only) is True:
            self.reason("sample_template_not_filled")

        template_generated = self.value("template_generated")
        if template_generated is not None and as_bool(template_generated) is True:
            self.reason("template_generated_evidence_not_raw_capture")

        evidence_source = self.value("evidence_source")
        if evidence_source is None:
            self.reason("missing_evidence_source")
        elif evidence_source == "template":
            self.reason("sample_template_not_filled")
        elif evidence_source not in {"manual_raw_capture", "directory_raw_capture"}:
            self.reason(f"invalid_evidence_source_{evidence_source}")

        evidence_capture_id = self.value("evidence_capture_id")
        if evidence_capture_id is None:
            self.reason("missing_evidence_capture_id")
        elif evidence_capture_id == "template":
            self.reason("sample_template_not_filled")

        swd = self.value("swd_status")
        if swd is None:
            self.reason("missing_swd_status")
        elif swd != "ok":
            self.hardware_offline = True
            self.reason(f"swd_status_{swd}")

        for key in (
            "firmware_build",
            "firmware_flash",
            "agent_connected",
            "topic_motor_target",
            "topic_motor_state",
            "topic_motor_health",
            "topic_com_status",
            "info_motor_target",
            "info_motor_state",
            "info_motor_health",
            "info_com_status",
        ):
            self.require_true(key)

        self.require_equal_int("state_after_accept_last_target_seq", args.accepted_seq)
        self.require_greater_int("state_after_accept_seq", "state_before_accept_seq")
        self.require_equal_int("state_after_reject_last_target_seq", args.accepted_seq)
        self.require_greater_int("state_after_reject_seq", "state_after_accept_seq")
        self.require_same_int(
            "health_before_reject_targets_received",
            "health_after_reject_targets_received",
        )
        baseline_enabled = self.require_bool("reject_baseline_target_enabled")
        if args.strict_applied_stable and baseline_enabled is False:
            self.require_same_int(
                "health_before_reject_targets_applied",
                "health_after_reject_targets_applied",
            )
        self.require_equal_int("state_after_legal_last_target_seq", args.legal_seq)
        self.require_greater_int("state_after_legal_seq", "state_after_reject_seq")
        self.require_equal_int("state_after_clamp_last_target_seq", args.clamp_seq)
        self.require_greater_int("state_after_clamp_seq", "state_after_legal_seq")
        self.require_bit("state_after_clamp_fault_bits", 4)
        self.require_lte_int("state_after_clamp_sample_age_us", "clamp_target_ttl_us")
        self.require_equal_int("state_after_ttl_last_target_seq", args.clamp_seq)
        self.require_greater_int("state_after_ttl_seq", "state_after_clamp_seq")
        ttl_fresh = self.require_bool("state_after_ttl_target_fresh")
        if ttl_fresh is True:
            self.reason("state_after_ttl_target_still_fresh")
        ttl_enabled = self.require_bool("state_after_ttl_enabled")
        if ttl_enabled is True:
            self.reason("state_after_ttl_still_enabled")
        self.require_bit("state_after_ttl_fault_bits", 2)
        before_stale = self.require_int("health_before_ttl_stale_targets")
        after_stale = self.require_int("health_after_ttl_stale_targets")
        if (
            before_stale is not None
            and after_stale is not None
            and after_stale <= before_stale
        ):
            self.reason(
                "health_after_ttl_stale_targets_not_increased_"
                f"{after_stale}_le_{before_stale}"
            )
        self.require_enabled_soak(args)
        self.require_rate("motor_state_hz", args.min_motor_state_hz, args.max_motor_state_hz)
        self.require_rate("motor_health_hz", args.min_motor_health_hz, args.max_motor_health_hz)
        self.require_rate("com_status_hz", args.min_com_status_hz, args.max_com_status_hz)
        self.require_rate(
            "com_status_soak_hz",
            args.min_com_status_hz,
            args.max_com_status_hz,
        )
        free_words = self.require_int("microros_stack_free_words")
        if free_words is not None and free_words < args.min_microros_stack_free_words:
            self.reason(
                "microros_stack_free_words_low_"
                f"{free_words}_lt_{args.min_microros_stack_free_words}"
            )
        heap_free = self.require_int("newlib_heap_free_before_msp_reserve_bytes")
        if heap_free is not None and heap_free < args.min_newlib_heap_free_before_msp_reserve_bytes:
            self.reason(
                "newlib_heap_free_before_msp_reserve_bytes_low_"
                f"{heap_free}_lt_{args.min_newlib_heap_free_before_msp_reserve_bytes}"
            )
        msp_reserved = self.require_int("newlib_heap_msp_reserved_bytes")
        if msp_reserved is not None and msp_reserved < args.min_newlib_heap_msp_reserved_bytes:
            self.reason(
                "newlib_heap_msp_reserved_bytes_low_"
                f"{msp_reserved}_lt_{args.min_newlib_heap_msp_reserved_bytes}"
            )
        session_loss = self.require_int("agent_session_loss_events")
        if session_loss is not None and session_loss > args.max_agent_session_loss_events:
            self.reason(
                "agent_session_loss_events_high_"
                f"{session_loss}_gt_{args.max_agent_session_loss_events}"
            )
        hardfault_seen = self.require_bool("hardfault_seen")
        if hardfault_seen is True:
            self.reason("hardfault_seen")

        if self.reasons:
            if self.hardware_offline:
                status = "BLOCKED_HARDWARE_OFFLINE"
            elif self.missing_evidence:
                status = "BLOCKED_MISSING_EVIDENCE"
            else:
                status = "FAIL"
            print(f"{status} motor_m2_smoke reason={';'.join(self.reasons)}")
            return 1
        print(
            "PASS motor_m2_smoke "
            f"accepted_seq={args.accepted_seq} legal_seq={args.legal_seq} "
            f"clamp_seq={args.clamp_seq} "
            f"motor_state_hz_range={args.min_motor_state_hz:g}..{args.max_motor_state_hz:g} "
            f"motor_health_hz_range={args.min_motor_health_hz:g}..{args.max_motor_health_hz:g} "
            f"com_status_hz_range={args.min_com_status_hz:g}..{args.max_com_status_hz:g} "
            f"enabled_soak_target_hz_range="
            f"{args.min_enabled_soak_target_hz:g}..{args.max_enabled_soak_target_hz:g} "
            f"min_enabled_soak_targets_sent={args.min_enabled_soak_targets_sent} "
            f"min_enabled_soak_received_ratio={args.min_enabled_soak_received_ratio:g} "
            f"min_enabled_soak_applied_per_received="
            f"{args.min_enabled_soak_applied_per_received:g} "
            f"min_enabled_soak_applied_delta={args.min_enabled_soak_applied_delta} "
            f"min_microros_stack_free_words={args.min_microros_stack_free_words} "
            f"min_newlib_heap_free_before_msp_reserve_bytes="
            f"{args.min_newlib_heap_free_before_msp_reserve_bytes} "
            f"min_newlib_heap_msp_reserved_bytes={args.min_newlib_heap_msp_reserved_bytes} "
            f"max_agent_session_loss_events={args.max_agent_session_loss_events}"
        )
        return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", nargs="?", type=Path)
    parser.add_argument("--template", action="store_true")
    parser.add_argument("--accepted-seq", type=int, default=42)
    parser.add_argument("--legal-seq", type=int, default=44)
    parser.add_argument("--clamp-seq", type=int, default=45)
    parser.add_argument("--strict-applied-stable", action="store_true", default=True)
    parser.add_argument("--min-motor-state-hz", type=float, default=45.0)
    parser.add_argument("--max-motor-state-hz", type=float, default=55.0)
    parser.add_argument("--min-motor-health-hz", type=float, default=4.5)
    parser.add_argument("--max-motor-health-hz", type=float, default=5.5)
    parser.add_argument("--min-com-status-hz", type=float, default=4.5)
    parser.add_argument("--max-com-status-hz", type=float, default=5.5)
    parser.add_argument("--min-enabled-soak-target-hz", type=float, default=180.0)
    parser.add_argument("--max-enabled-soak-target-hz", type=float, default=220.0)
    parser.add_argument("--min-enabled-soak-targets-sent", type=int, default=100)
    parser.add_argument("--min-enabled-soak-received-ratio", type=float, default=0.9)
    parser.add_argument("--min-enabled-soak-applied-per-received", type=float, default=40.0)
    parser.add_argument("--min-enabled-soak-applied-delta", type=int, default=1)
    parser.add_argument("--max-enabled-soak-last-target-lag", type=int, default=0)
    parser.add_argument("--min-microros-stack-free-words", type=int, default=128)
    parser.add_argument("--min-newlib-heap-free-before-msp-reserve-bytes", type=int, default=0)
    parser.add_argument("--min-newlib-heap-msp-reserved-bytes", type=int, default=512)
    parser.add_argument("--max-agent-session-loss-events", type=int, default=0)
    args = parser.parse_args()

    if args.template:
        print(TEMPLATE, end="")
        return 0
    if args.evidence is None:
        parser.error("evidence file is required unless --template is used")
    try:
        if args.evidence.is_dir():
            values = read_evidence_dir(args.evidence)
        else:
            values = read_evidence(args.evidence)
            values["_evidence_path_kind"] = "file"
    except OSError as exc:
        print(f"FAIL motor_m2_smoke reason=evidence_read_failed:{exc}")
        return 1
    except ValueError as exc:
        print(f"FAIL motor_m2_smoke reason=evidence_parse_failed:{exc}")
        return 1
    return Checker(values).check(args)


if __name__ == "__main__":
    raise SystemExit(main())
