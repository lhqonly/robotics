#!/usr/bin/env bash
# Emit the next hardware staircase command from current scheduler evidence.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHED_LOGDIR="${SCHED_LOGDIR:-$ROOT/log/pc-scheduler-sweep}"
SCHEDULER_CSV="${SCHEDULER_CSV:-}"
SUMMARY="${SUMMARY:-}"
STAIRCASE_BAUDS="${STAIRCASE_BAUDS:-921600 2000000}"
STAIRCASE_EXECUTOR_SPIN_TIMEOUT_US="${STAIRCASE_EXECUTOR_SPIN_TIMEOUT_US:-1000 100}"
STAIRCASE_CONTRACT_ARGS="${STAIRCASE_CONTRACT_ARGS:---max-pc-catchup-events 0 --max-pc-catchup-extra 0}"
TAG_PREFIX="${TAG_PREFIX:-staircase_$(date +%Y%m%d_%H%M)}"
FORMAT="${FORMAT:-markdown}"
EXPECTED_CMD_RATE_HZ="${EXPECTED_CMD_RATE_HZ:-200}"
EXPECTED_CMD_CATCHUP_MAX="${EXPECTED_CMD_CATCHUP_MAX:-0}"
EXPECTED_QOS_RELIABILITY="${EXPECTED_QOS_RELIABILITY:-best_effort}"
EXPECTED_TRACKING_MODE="${EXPECTED_TRACKING_MODE:-sampled}"
EXPECTED_STATUS_EVERY_N="${EXPECTED_STATUS_EVERY_N:-40}"

latest_file() {
  local dir="$1"
  local pattern="$2"
  find "$dir" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %p\n' 2>/dev/null |
    sort -nr |
    awk 'NR == 1 {sub(/^[^ ]+ /, ""); print; exit}' || true
}

summary_matches_expected_profile() {
  local summary="$1"
  local profile

  [ -f "$summary" ] || return 1
  profile="$(grep '^profile ' "$summary" | tail -1 || true)"
  [ -n "$profile" ] || return 1

  case " $profile " in
    *" cmd_rate_hz=$EXPECTED_CMD_RATE_HZ "*) ;;
    *) return 1 ;;
  esac
  case " $profile " in
    *" cmd_catchup_max=$EXPECTED_CMD_CATCHUP_MAX "*) ;;
    *) return 1 ;;
  esac
  case " $profile " in
    *" qos=$EXPECTED_QOS_RELIABILITY "*) ;;
    *) return 1 ;;
  esac
  case " $profile " in
    *" tracking=$EXPECTED_TRACKING_MODE "*) ;;
    *) return 1 ;;
  esac
  case " $profile " in
    *" status_every_n=$EXPECTED_STATUS_EVERY_N "*) ;;
    *) return 1 ;;
  esac
}

latest_matching_scheduler_csv() {
  local csv summary
  while IFS= read -r csv; do
    summary="${csv%.metrics.csv}.summary.log"
    if summary_matches_expected_profile "$summary"; then
      printf '%s\n' "$csv"
      return 0
    fi
  done < <(
    find "$SCHED_LOGDIR" -maxdepth 1 -type f -name '*.metrics.csv' -printf '%T@ %p\n' 2>/dev/null |
      sort -nr |
      awk '{sub(/^[^ ]+ /, ""); print}'
  )
}

relpath() {
  local path="${1:-}"
  if [ -z "$path" ]; then
    printf '-'
  else
    printf '%s' "${path#$ROOT/}"
  fi
}

shell_quote() {
  local value="$1"
  printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
}

best_scheduler_tag() {
  local csv="$1"
  awk -F, '
    NR == 1 {
      for (i = 1; i <= NF; i++) col[$i] = i
      next
    }
    function num(value) {
      return (value == "" || value == "NA" || value == "-") ? 1e99 : value + 0
    }
    col["tag"] && col["pc_wire_gap_p99_ms"] && col["pc_wire_gap_max_ms"] {
      p99 = num($col["pc_wire_gap_p99_ms"])
      maxgap = num($col["pc_wire_gap_max_ms"])
      extra = num($col["pc_cmd_catchup_extra"])
      events = num($col["pc_cmd_catchup_events"])
      if (!seen || p99 < best_p99 ||
          (p99 == best_p99 && maxgap < best_max) ||
          (p99 == best_p99 && maxgap == best_max && extra < best_extra) ||
          (p99 == best_p99 && maxgap == best_max &&
           extra == best_extra && events < best_events)) {
        seen = 1
        best_tag = $col["tag"]
        best_p99 = p99
        best_max = maxgap
        best_extra = extra
        best_events = events
      }
    }
    END {
      if (seen) print best_tag
    }
  ' "$csv"
}

row_metric() {
  local csv="$1"
  local tag="$2"
  local key="$3"
  awk -F, -v tag="$tag" -v key="$key" '
    NR == 1 {
      for (i = 1; i <= NF; i++) col[$i] = i
      next
    }
    col["tag"] && col[key] && $col["tag"] == tag {
      print $col[key]
      exit
    }
  ' "$csv"
}

SCHEDULER_CSV="${SCHEDULER_CSV:-$(latest_matching_scheduler_csv)}"
if [ -z "$SCHEDULER_CSV" ] || [ ! -f "$SCHEDULER_CSV" ]; then
  echo "ERROR: no matching scheduler metrics CSV found; run tools/run-pc-latest-scheduler-sweep.sh first" >&2
  exit 1
fi

SUMMARY="${SUMMARY:-${SCHEDULER_CSV%.metrics.csv}.summary.log}"
if [ ! -f "$SUMMARY" ]; then
  echo "ERROR: scheduler summary not found: $SUMMARY" >&2
  exit 1
fi

best_tag="$(best_scheduler_tag "$SCHEDULER_CSV")"
if [ -z "$best_tag" ]; then
  echo "ERROR: no scheduler candidate with pc_wire_gap_p99_ms found in $SCHEDULER_CSV" >&2
  exit 1
fi

start_line="$(grep -F " tag=$best_tag " "$SUMMARY" | grep '^START ' | head -1 || true)"
if [ -z "$start_line" ]; then
  echo "ERROR: selected scheduler tag not found in summary: $best_tag" >&2
  exit 1
fi

label="$(printf '%s\n' "$start_line" |
  sed -nE 's/.* label=([^ ]+) run=.*/\1/p')"
prefix="$(printf '%s\n' "$start_line" |
  sed -nE 's/.* prefix=(.*) executor_threads=.*/\1/p')"
executor_threads="$(printf '%s\n' "$start_line" |
  sed -nE 's/.* executor_threads=([^ ]+) stage_ros_domain_id=.*/\1/p')"
if [ "$prefix" = "none" ]; then
  prefix=""
fi
if [ -z "$label" ] || [ -z "$executor_threads" ]; then
  echo "ERROR: could not parse scheduler case from summary line: $start_line" >&2
  exit 1
fi

selected_case="$label|$prefix|$executor_threads"
if [ "$label" = "default" ] && [ -z "$prefix" ] && [ "$executor_threads" = "0" ]; then
  staircase_cases=("default|")
else
  staircase_cases=("default|" "$selected_case")
fi

if [ "$FORMAT" = "cases" ]; then
  printf '%s\n' "${staircase_cases[@]}"
  exit 0
fi
if [ "$FORMAT" != "markdown" ]; then
  echo "ERROR: FORMAT must be markdown or cases, got '$FORMAT'" >&2
  exit 1
fi

printf '# Recommended Communication Staircase Command\n\n'
printf -- '- scheduler CSV: %s\n' "$(relpath "$SCHEDULER_CSV")"
printf -- '- scheduler summary: %s\n' "$(relpath "$SUMMARY")"
printf -- '- selected scheduler tag: %s\n' "$best_tag"
printf -- '- selected case: label=%s prefix=%s executor_threads=%s\n' \
  "$label" "${prefix:-none}" "$executor_threads"
printf -- '- selected gaps: p99_ms=%s max_ms=%s catchup=%s/%s\n\n' \
  "$(row_metric "$SCHEDULER_CSV" "$best_tag" pc_wire_gap_p99_ms)" \
  "$(row_metric "$SCHEDULER_CSV" "$best_tag" pc_wire_gap_max_ms)" \
  "$(row_metric "$SCHEDULER_CSV" "$best_tag" pc_cmd_catchup_events)" \
  "$(row_metric "$SCHEDULER_CSV" "$best_tag" pc_cmd_catchup_extra)"

printf 'Gate: run `tools/diagnose-swd.sh` first; only run this staircase when `SWD_STATUS=ok`.\n\n'
printf '```bash\n'
printf 'STAIRCASE_BAUDS=%s \\\n' "$(shell_quote "$STAIRCASE_BAUDS")"
printf 'STAIRCASE_EXECUTOR_SPIN_TIMEOUT_US=%s \\\n' \
  "$(shell_quote "$STAIRCASE_EXECUTOR_SPIN_TIMEOUT_US")"
printf 'STAIRCASE_PC_LAUNCH_PREFIX_CASES="$(printf '\''%%s\\n'\'' '
for staircase_case in "${staircase_cases[@]}"; do
  printf '%s ' "$(shell_quote "$staircase_case")"
done
printf ')" \\\n'
printf 'tools/run-com-staircase.sh %s\n' "$(shell_quote "$TAG_PREFIX")"
printf '```\n'
printf '\nThen run the matching acceptance contract:\n\n'
printf '```bash\n'
printf 'tools/check-com-staircase-contract.py %s %s\n' \
  "$(shell_quote "log/com-staircase/$TAG_PREFIX.metrics.csv")" \
  "$STAIRCASE_CONTRACT_ARGS"
printf '```\n'
