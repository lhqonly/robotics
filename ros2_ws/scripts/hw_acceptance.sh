#!/usr/bin/env bash
# =============================================================================
# Real-hardware acceptance for WSL(ROS2 Jazzy) <-> Nucleo-F103RB(micro-ROS)
# bidirectional pub/sub over serial.  (designed by Gill; run by 主 agent)
#
# This is NOT a loopback test. The micro-ROS Agent + the real board replace the
# loopback_node. exo_cmd_node (WSL side) is the SAME node used in Phase A: it
# publishes /exo/cmd_heartbeat and subscribes /exo/mcu_status with the v1.1
# LinkHealthTracker. The board echoes cmd_heartbeat.data back on mcu_status.
#
# Prereqs (主 agent verifies before running):
#   - usbipd attached, /dev/ttyACM0 present & openable @921600 (G-B-1 done)
#   - firmware flashed onto F103 (T4/T5/T8 done)
#   - micro_ros_agent built/installed (T3 done)
#
# Usage:
#   hw_acceptance.sh <phase> [run_seconds]
#     phase = session | uni | bidi | endurance | all
#     run_seconds default per-phase below
#
# Exit code 0 = phase PASS, non-zero = FAIL (grep the .log files for evidence).
# Everything is killed by process group (setsid + kill -- -PGID), per the
# 2026-06-18 orphan-crosstalk lesson (see tools/run-scenario.sh).
# =============================================================================
set +u
source /opt/ros/jazzy/setup.bash
source /home/lhq24/robotics/ros2_ws/install/setup.bash
set -uo pipefail

# Contract v1.3+: comms port = independent USB-TTL on USART1 = /dev/ttyUSB0.
# (ST-Link /dev/ttyACM0 is SWD-flash ONLY, not the micro-ROS serial.)
DEV="${EXO_DEV:-/dev/ttyUSB0}"
BAUD="${EXO_BAUD:-921600}"
LOGDIR=/home/lhq24/robotics/log
mkdir -p "$LOGDIR"
PHASE="${1:-all}"
SECS="${2:-}"

# DDS domain: the F103 micro-ROS client creates its participant on domain 0
# (firmware leaves RMW_UXRCE_DEFAULT_DOMAIN_ID unset -> 0; the agent bridges it
# onto whatever ROS_DOMAIN_ID the agent runs in, but the client-declared domain
# is what `ros2 node list` matches). Forcing a non-zero domain here made UNI
# fail ("/exo_mcu not visible") because the board stays on 0. So default to 0;
# isolation still comes from ROS_LOCALHOST_ONLY below. To isolate on a non-zero
# domain you must ALSO rebuild firmware with RMW_UXRCE_DEFAULT_DOMAIN_ID set.
export ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}"
# Single-host test: restrict discovery to localhost so no remote participant
# can supply a fake /exo_mcu or extra publisher. (CycloneDDS/FastDDS honor this.)
export ROS_LOCALHOST_ONLY="${ROS_LOCALHOST_ONLY:-1}"
echo "DDS isolation: ROS_DOMAIN_ID=$ROS_DOMAIN_ID ROS_LOCALHOST_ONLY=$ROS_LOCALHOST_ONLY"

AGENT_LOG="$LOGDIR/hw_agent.log"
CMD_LOG="$LOGDIR/hw_cmd.log"
ECHO_LOG="$LOGDIR/hw_echo.log"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
grn()   { printf '\033[32m%s\033[0m\n' "$*"; }
hr()    { printf '%s\n' "------------------------------------------------------------"; }

# --- preflight: no orphan exo / agent from a previous run -------------------
preflight() {
  local leak
  # process check: agent / exo_cmd_node / loopback (loopback must NOT be running
  # in a real-HW test -- it would fake the echo) / serial terminals.
  leak=$(pgrep -f 'exo_cmd/lib/exo_cmd/(exo_cmd_node|loopback_node)|micro_ros_agent' | tr '\n' ' ')
  if [ -n "$leak" ]; then
    red "PREFLIGHT FAIL: stale exo_cmd_node/loopback_node/micro_ros_agent PIDs: $leak"
    red "Kill them first (kill -9 $leak) so DDS graph is clean. Aborting."
    exit 2
  fi
  # serial terminals that pgrep above won't catch and that would steal the port
  local term
  term=$(pgrep -f 'screen|minicom|picocom|cu ' | tr '\n' ' ')
  [ -n "$term" ] && { red "PREFLIGHT WARN: serial terminal PIDs present: $term (may hold $DEV)"; }
  if [ ! -e "$DEV" ]; then
    red "PREFLIGHT FAIL: $DEV does not exist. usbipd attach + flash first."
    exit 2
  fi
  # HARD gate: nobody may already own the port (Codex finding -- a single open()
  # success does not prove exclusivity; check the OS view of holders).
  local holders=""
  command -v fuser >/dev/null && holders=$(fuser "$DEV" 2>/dev/null | tr -d ' ')
  if [ -z "$holders" ] && command -v lsof >/dev/null; then
    holders=$(lsof -t "$DEV" 2>/dev/null | tr '\n' ' ')
  fi
  if [ -n "$holders" ]; then
    red "PREFLIGHT FAIL: $DEV already held by PID(s): $holders"
    red "  (Windows tool over usbip? a second agent? screen/minicom?) Aborting."
    exit 2
  fi
  # device must be openable (not held by Windows / another agent)
  if ! { exec 9<>"$DEV"; } 2>/dev/null; then
    red "PREFLIGHT FAIL: cannot open $DEV (busy? permissions? Windows holding it?)"
    exit 2
  fi
  exec 9>&-
  # DDS graph must be empty of /exo/* before WE create anything (Codex finding).
  local pre_topics
  pre_topics=$(ros2 topic list 2>/dev/null | grep '^/exo/' || true)
  if [ -n "$pre_topics" ]; then
    red "PREFLIGHT FAIL: /exo/* topics already on the graph BEFORE we start:"
    echo "$pre_topics"
    red "  Something else is publishing on this domain. Aborting (would crosstalk)."
    exit 2
  fi
  grn "preflight OK: clean graph, no /exo/* preexisting, $DEV free & openable"
}

start_agent() {
  # IMPORTANT: agent must own the serial port. Nothing else (no screen/minicom,
  # no second agent, no Windows tool) may have /dev/ttyACM0 open.
  setsid ros2 run micro_ros_agent micro_ros_agent serial \
      --dev "$DEV" -b "$BAUD" -v6 > "$AGENT_LOG" 2>&1 &
  AGENT_PGID=$!
  echo "agent started pgid=$AGENT_PGID -> $AGENT_LOG"
}

stop_all() {
  for p in "${AGENT_PGID:-}" "${CMD_PGID:-}"; do
    [ -n "$p" ] && kill -TERM -- -"$p" 2>/dev/null || true
  done
  sleep 1
  for p in "${AGENT_PGID:-}" "${CMD_PGID:-}"; do
    [ -n "$p" ] && kill -9 -- -"$p" 2>/dev/null || true
  done
  sleep 1
  local leak
  leak=$(pgrep -f 'exo_cmd/lib/exo_cmd/exo_cmd_node|micro_ros_agent' | tr '\n' ' ')
  [ -n "$leak" ] && { red "LEAK after stop: $leak"; kill -9 $leak 2>/dev/null || true; }
}
trap stop_all EXIT

# === wait helper: poll a condition up to N sec ==============================
wait_for() {  # wait_for <timeout_s> <bash-cmd...>
  local t="$1"; shift
  local i=0
  while [ "$i" -lt "$t" ]; do
    if eval "$@"; then return 0; fi
    sleep 1; i=$((i+1))
  done
  return 1
}

# ===========================================================================
# PHASE 1 : SESSION  -- agent <-> client XRCE session established
# ===========================================================================
phase_session() {
  hr; echo "PHASE 1: SESSION (agent <-> F103 micro-ROS client)"; hr
  preflight
  start_agent
  echo "Reset the board now if it does not auto-reconnect (NRST)..."
  # The board must establish an XRCE session. Look for the agent's key lines.
  if wait_for 30 'grep -qiE "create_(client|session)|client_key|Client connected|session established" "$AGENT_LOG"'; then
    grn "SESSION: agent reports client connected"
  else
    red "SESSION FAIL: no client-connected line in 30s. See $AGENT_LOG"
    red "  (board not flashed? wrong baud? agent didn't get the port? framing?)"
    return 1
  fi
  # Agent process must still be alive (it can connect then die on a bad frame).
  if ! kill -0 -- -"$AGENT_PGID" 2>/dev/null && ! pgrep -f micro_ros_agent >/dev/null; then
    red "SESSION FAIL: agent process exited after connecting. See $AGENT_LOG tail:"
    tail -20 "$AGENT_LOG"; return 1
  fi
  # No transport/open errors in the log.
  if grep -qiE "error|permission denied|could not open|bad frame|deserializ|stream error" "$AGENT_LOG"; then
    red "SESSION WARN: agent log contains error lines (inspect, may still be transient):"
    grep -iE "error|permission denied|could not open|bad frame|deserializ|stream error" "$AGENT_LOG" | tail -10
  fi
  # CRITICAL false-positive guard (micro-ROS Agent issue #102 "create only
  # client and participant"): session+participant can succeed while NO
  # datawriter/datareader is ever created -> agent looks alive, zero app traffic.
  # SESSION is only really up when BOTH a datawriter AND a datareader exist
  # (board pub on mcu_status + board sub on cmd_heartbeat).
  if wait_for 15 'grep -qi "create_datawriter" "$AGENT_LOG"' && \
     wait_for 15 'grep -qi "create_datareader" "$AGENT_LOG"'; then
    grn "SESSION: datawriter AND datareader created (real entities, not just session)"
  else
    red "SESSION FAIL: session up but datawriter/datareader NOT both created."
    red "  This is the 'looks alive but no topic match' trap (agent issue #102):"
    red "  board created client+participant but failed to create endpoints"
    red "  (micro-ROS pool exhausted? entity-creation/refs error? RAM?). See log:"
    grep -iE "create_(participant|topic|publisher|subscriber|datawriter|datareader)|error|denied" "$AGENT_LOG" | tail -20
    return 1
  fi
  echo "--- agent session lines ---"
  grep -iE "create_(client|session|participant|topic|publisher|subscriber|datawriter|datareader)|matched|client_key" "$AGENT_LOG" | tail -40
  # Re-session detection baseline: count create_client occurrences now; >1 over a
  # short window at startup is one reconnect (ok), but climbing during BIDI =
  # board resetting (checked again in phase_bidi / endurance).
  local nclient
  # Count ONLY the actual session-creation log line. NOT client_key: every -v6
  # send/recv debug line carries "client_key: 0x..", so grepping client_key
  # counts thousands and false-flags a healthy run as "board resetting".
  nclient=$(grep -ci "create_client" "$AGENT_LOG")
  echo "create_client count so far: $nclient (watch this -- climbing = board resets)"
  return 0
}

# ===========================================================================
# PHASE 2 : UNI -- ROS2 graph sees the MCU node + its topics
#           (entities created; one direction observable)
# ===========================================================================
phase_uni() {
  hr; echo "PHASE 2: UNI (ROS2 graph discovers exo_mcu + topics)"; hr
  # exo_mcu node visible
  if wait_for 20 'ros2 node list 2>/dev/null | grep -q "/exo_mcu\|exo_mcu"'; then
    grn "UNI: exo_mcu node present in ROS2 graph"
  else
    red "UNI FAIL: exo_mcu not in 'ros2 node list'. Session up but no node/entities."
    ros2 node list 2>/dev/null || true
    return 1
  fi
  echo "--- ros2 node list ---"; ros2 node list
  echo "--- ros2 topic list ---"; ros2 topic list
  # both contract topics present
  for t in /exo/cmd_heartbeat /exo/mcu_status; do
    if ros2 topic list 2>/dev/null | grep -qx "$t"; then grn "  topic $t present";
    else red "  topic $t MISSING"; return 1; fi
  done
  # the board must be publishing mcu_status. Confirm with hz BEFORE we drive it:
  # if it's purely responsive (echo only), there may be 0 Hz until we publish.
  # So we ALSO need a publisher running; that is phase_bidi's job. Here we only
  # assert the entity/QoS side.
  echo "--- ros2 topic info -v /exo/mcu_status (publisher = exo_mcu, QoS) ---"
  ros2 topic info -v /exo/mcu_status
  echo "--- ros2 topic info -v /exo/cmd_heartbeat (subscriber = exo_mcu, QoS) ---"
  ros2 topic info -v /exo/cmd_heartbeat
  echo "CHECK MANUALLY: mcu_status Reliability=RELIABLE, History=KEEP_LAST."
  echo "(Depth shows UNKNOWN via rmw -- expected, not a defect.)"

  # --- endpoint provenance gates (Codex finding: node-list alone proves nothing)
  # mcu_status MUST be published by exactly one exo_mcu and nothing else.
  local pubcnt fakeloop
  pubcnt=$(ros2 topic info /exo/mcu_status 2>/dev/null | sed -nE 's/.*Publisher count: *([0-9]+).*/\1/p')
  echo "mcu_status publisher count = ${pubcnt:-?}"
  if [ "${pubcnt:-0}" != "1" ]; then
    red "UNI FAIL: /exo/mcu_status publisher count = ${pubcnt:-0}, expected exactly 1 (the board)."
    red "  >1 means a fake/loopback/second source is also publishing -> echo could be faked."
    return 1
  fi
  # Reliability check. IMPORTANT: `ros2 topic info -v` endpoint detail is
  # unreliable for micro-ROS *bridged* endpoints -- the daemon frequently returns
  # EMPTY -v output even when the (cached) publisher count is 1. So we cannot
  # treat "no RELIABLE line" as "NOT RELIABLE". Distinguish three cases:
  #   - observed RELIABLE          -> pass
  #   - observed BEST_EFFORT        -> real QoS mismatch -> FAIL
  #   - could not observe at all    -> known CLI limitation -> NOTE + continue;
  #       BIDI is the authoritative QoS gate (a true RELIABLE/BEST_EFFORT
  #       mismatch leaves the endpoints unmatched -> zero matched there).
  local qos_dump=""
  wait_for 10 'ros2 topic info -v /exo/mcu_status 2>/dev/null | grep -qi "Reliability:"' || true
  qos_dump=$(ros2 topic info -v /exo/mcu_status 2>/dev/null)
  if echo "$qos_dump" | grep -qi "Reliability: *RELIABLE"; then
    grn "  mcu_status endpoint QoS observed RELIABLE"
  elif echo "$qos_dump" | grep -qi "Reliability:"; then
    red "UNI FAIL: /exo/mcu_status board endpoint QoS is NOT RELIABLE:"
    echo "$qos_dump" | grep -i "Reliability:"
    return 1
  else
    echo "  UNI NOTE: 'topic info -v' returned no endpoint QoS (known micro-ROS /"
    echo "  daemon limitation); deferring the QoS proof to BIDI -- a RELIABLE"
    echo "  mismatch would zero out matched there."
  fi
  # No loopback node may exist in a real-HW test.
  if ros2 node list 2>/dev/null | grep -qi "loopback"; then
    red "UNI FAIL: a loopback node is on the graph -- this is a REAL hardware test, kill it."
    return 1
  fi
  grn "UNI: provenance OK (exactly 1 board publisher on mcu_status, no loopback)"
  echo "NOTE: F103 Depth=1 is NOT observable via DDS CLI (rmw doesn't expose remote depth)."
  echo "      Verify Depth=1 from FIRMWARE build evidence (RMW_UXRCE_MAX_HISTORY=1 in colcon.meta)."
  return 0
}

# ===========================================================================
# PHASE 3 : BIDI -- real end-to-end roundtrip, value sequence consistent
# ===========================================================================
phase_bidi() {
  hr; echo "PHASE 3: BIDI (WSL drives cmd_heartbeat, board echoes mcu_status)"; hr
  local run="${SECS:-30}"
  local deadline_s=0.2   # rtt_deadline_ms default = 200ms
  # Drive the link with the real exo_cmd_node (10 Hz heartbeat + link health).
  setsid ros2 run exo_cmd exo_cmd_node > "$CMD_LOG" 2>&1 &
  CMD_PGID=$!
  echo "exo_cmd_node started pgid=$CMD_PGID -> $CMD_LOG"
  # WARMUP: exo_cmd_node publishes at 10 Hz the instant it starts, but its
  # cmd_heartbeat publisher takes a couple seconds to DDS-match the board's
  # datareader (esp. bridged via the agent). Those first sends get no echo and
  # settle LOST -- a discovery-handshake artifact, NOT a steady-state link fault.
  # Wait for the link to actually carry echoes (matched climbing), then snapshot
  # a BASELINE so the loss/throughput gates below measure STEADY STATE only (the
  # contract's zero-loss is a steady-state requirement). reconcile/UNMATCHED/
  # re-session checks still use the cumulative totals.
  local base_sent=0 base_matched=0 base_lost=0
  if wait_for 15 'grep -oE "matched=[0-9]+" "$CMD_LOG" | tail -1 | grep -qE "matched=([5-9]|[0-9]{2,})"'; then
    sleep 1
    local bline
    bline=$(grep -iE "sent=.*matched=.*lost=.*inflight=" "$CMD_LOG" | tail -1)
    base_sent=$(sed -nE 's/.*sent=([0-9]+).*/\1/p' <<<"$bline")
    base_matched=$(sed -nE 's/.*matched=([0-9]+).*/\1/p' <<<"$bline")
    base_lost=$(sed -nE 's/.*lost=([0-9]+).*/\1/p' <<<"$bline")
    echo "warmup done (link matched): baseline sent=$base_sent matched=$base_matched lost=$base_lost"
  else
    red "  BIDI WARN: link did not start matching within 15s warmup -- measuring from 0 (expect startup losses)."
  fi
  # capture the echo stream independently as ground truth (causality cross-check)
  setsid timeout "$run" ros2 topic echo /exo/mcu_status std_msgs/msg/Int32 \
      > "$ECHO_LOG" 2>&1 &
  # let it run (measured steady-state window)
  sleep "$run"

  # CAUSALITY: stop the publisher, wait > 2*deadline, then the tracker MUST drain
  # inflight to 0 (every outstanding seq settles to matched or lost). A board
  # that is publishing AUTONOMOUSLY (not echoing) would keep producing values we
  # never sent -> shows up as UNMATCHED; and if WSL->MCU is dead, the values we
  # DID send all settle as LOST. Either way the drained state is diagnostic.
  echo "stopping publisher, draining inflight (wait $(awk "BEGIN{print 2*$deadline_s+0.5}")s)..."
  kill -TERM -- -"$CMD_PGID" 2>/dev/null || true
  sleep 1   # let the node print its shutdown / final state

  echo "--- ros2 topic hz: NOTE this is WEAK proof. Run in a SEPARATE shell DURING"
  echo "    the run: 'ros2 topic hz /exo/mcu_status' (~10Hz). Rate alone can be"
  echo "    faked by an autonomous board publisher -- the AUTHORITATIVE proof is"
  echo "    the tracker's matched count + zero UNMATCHED below (value causality)."
  hr
  echo "=== EVIDENCE: exo_cmd link-health summary (authoritative correctness) ==="
  # The tracker prints RECONCILE / sent/matched/lost/duplicate/inflight lines.
  grep -iE "RECONCILE|sent=|matched=|lost=|duplicate=|inflight=|UNMATCHED|WARN|LOST" "$CMD_LOG" | tail -40
  hr

  # --- automated PASS/FAIL on the tracker's own accounting -------------------
  # Pull the LAST summary line and parse the five counters.
  local line sent matched lost dup infl
  line=$(grep -iE "sent=.*matched=.*lost=.*duplicate=.*inflight=" "$CMD_LOG" | tail -1)
  if [ -z "$line" ]; then
    red "BIDI FAIL: no link-health summary line. Was exo_cmd_node alive? Did echoes arrive?"
    return 1
  fi
  echo "last summary: $line"
  sent=$(sed -nE 's/.*sent=([0-9]+).*/\1/p'      <<<"$line")
  matched=$(sed -nE 's/.*matched=([0-9]+).*/\1/p' <<<"$line")
  lost=$(sed -nE 's/.*lost=([0-9]+).*/\1/p'       <<<"$line")
  dup=$(sed -nE 's/.*duplicate=([0-9]+).*/\1/p'   <<<"$line")
  infl=$(sed -nE 's/.*inflight=([0-9]+).*/\1/p'   <<<"$line")
  echo "parsed: sent=$sent matched=$matched lost=$lost duplicate=$dup inflight=$infl"

  local ok=0
  # 1) reconcile identity must hold (no silent eviction)
  if [ $((matched + lost + infl)) -ne "$sent" ]; then
    red "  FAIL reconcile: matched+lost+inflight ($((matched+lost+infl))) != sent ($sent)"
    ok=1
  else grn "  OK reconcile: $sent == $matched+$lost+$infl"; fi
  # 2) inflight must be SMALL -- the link is not backlogging. NOTE: exo_cmd_node
  #    is SIGKILLed at stop, so it cannot run a final sweep to settle its last
  #    in-flight send(s); the last summary therefore shows the 1-2 messages that
  #    were legitimately in flight at the sampling instant (normal at 10 Hz with
  #    sub-100ms RTT). A genuine STALL shows inflight growing large (sent far
  #    ahead of matched+lost). So fail only when inflight exceeds a small bound.
  #    (True drain-to-0 needs exo_cmd_node to catch SIGTERM, sweep, print a final
  #    summary -- a noted Phase B follow-up.)
  local infl_max="${EXO_INFLIGHT_MAX:-3}"
  if [ "${infl:-99}" -gt "$infl_max" ]; then
    red "  FAIL drain: inflight=$infl > $infl_max at stop -> link backlogging/stalled (sent outrunning echoes)."
    ok=1
  else grn "  OK drain: inflight=$infl small (<= $infl_max; link not backlogged)"; fi
  # STEADY-STATE deltas: subtract the warmup baseline so the discovery-handshake
  # startup losses are excluded from the loss/throughput gates (reconcile and
  # UNMATCHED stay on the cumulative totals -- they must hold even with warmup).
  local s_sent=$((sent - base_sent)) s_matched=$((matched - base_matched))
  local s_lost=$((lost - base_lost))
  echo "steady-state (post-warmup): d_sent=$s_sent d_matched=$s_matched d_lost=$s_lost" \
       "(warmup baseline: sent=$base_sent matched=$base_matched lost=$base_lost)"
  # 3) throughput near the real 10 Hz over the STEADY window: matched delta >=
  #    0.95 * 10 * run.
  local minexp
  minexp=$(awk "BEGIN{printf \"%d\", 0.95*10*$run}")
  if [ "$s_matched" -lt "$minexp" ]; then
    red "  FAIL throughput: steady matched=$s_matched < expected>=$minexp (0.95*10Hz*${run}s). Link underperforming."
    ok=1
  else grn "  OK throughput: steady matched=$s_matched (>= $minexp, ~full 10Hz)"; fi
  # 4) zero UNMATCHED (wrong/never-sent values) -- real error, must be 0.
  #    On real HW this ALSO catches an autonomous board publisher emitting values
  #    we never sent. NB Gill finding #1: a stale-retransmit past settled_window
  #    is ALSO reported UNMATCHED today (false positive) -- so if UNMATCHED fires,
  #    inspect whether the value WAS ever sent before declaring a board bug.
  if grep -qi "UNMATCHED" "$CMD_LOG"; then
    red "  FAIL: UNMATCHED present -> board echoed a value never sent, OR stale-retransmit"
    red "        false positive (Gill finding #1). Inspect the values:"
    grep -i "UNMATCHED" "$CMD_LOG" | head
    ok=1
  else grn "  OK: zero UNMATCHED"; fi
  # 5) board re-session during BIDI = silent reset; must FAIL (Codex finding).
  #    Compare create_client count now vs. an empty baseline: more than the
  #    initial 1-2 connects means the board reset mid-run.
  local nclient
  # Count ONLY the actual session-creation log line. NOT client_key: every -v6
  # send/recv debug line carries "client_key: 0x..", so grepping client_key
  # counts thousands and false-flags a healthy run as "board resetting".
  nclient=$(grep -ci "create_client" "$AGENT_LOG")
  echo "  agent create_client count = $nclient"
  if [ "$nclient" -gt 2 ]; then
    red "  FAIL: agent re-created client $nclient times -> board is RESETTING mid-run"
    red "        (stack overflow? brownout? watchdog?). A reset is NOT a brief pause."
    grep -iE "create_client|client_key|disconnect|timeout|session.*(lost|closed)" "$AGENT_LOG" | tail
    ok=1
  else grn "  OK: no mid-run re-sessioning (create_client count <= 2)"; fi
  # 6) lost: on a real safety link ANY STEADY-STATE loss is an event. Acceptance =
  #    zero steady-state loss budget by default (override EXO_LOSS_BUDGET=N). The
  #    warmup baseline is subtracted so the DDS-handshake startup losses do not
  #    count; if those were nonzero we surface them as an explained note.
  local budget="${EXO_LOSS_BUDGET:-0}"
  local warm_lost="$base_lost"
  if [ "${s_lost:-0}" -gt "$budget" ]; then
    red "  FAIL: steady lost=$s_lost > budget=$budget. Real-link STEADY-STATE loss is a SAFETY EVENT."
    red "        Explain it (baud mismatch/clock? 921600 framing? Depth=1 overwrite?)."
    ok=1
  elif [ "${s_lost:-0}" -gt 0 ]; then
    red "  ATTENTION: steady lost=$s_lost (within budget $budget) -- still must be explained."
  else grn "  OK: zero steady-state loss"; fi
  if [ "${warm_lost:-0}" -gt 0 ]; then
    echo "  note: ${warm_lost} warmup (pre-match) losses excluded from the budget --"
    echo "        DDS discovery handshake before the board datareader matched; benign."
  fi
  if [ "${dup:-0}" -gt 0 ]; then
    echo "  note: duplicate=$dup (RELIABLE retransmit; nonzero implies the link"
    echo "        needed retransmits -> physical margin is thin even if matched is full)."
  fi
  # 7) causality cross-check from the independent echo capture
  echo "  echo-capture lines: $(grep -c 'data:' "$ECHO_LOG" 2>/dev/null || echo 0) (independent ground-truth of mcu_status values)"
  echo "  --- WSL nonce limitation: exo_cmd_node always starts the counter at 0."
  echo "      A board that REPLAYS an old 0.. sequence (or autonomously counts from 0)"
  echo "      could alias a fresh run. RECOMMEND Tom add a 'start_value' param so each"
  echo "      run uses a random 31-bit nonce -> echoed values prove THIS run's causality."
  return $ok
}

# ===========================================================================
# PHASE 4 : ENDURANCE -- run long, watch for drift / stall / agent disconnect
# ===========================================================================
phase_endurance() {
  hr; echo "PHASE 4: ENDURANCE (long soak, ${SECS:-600}s)"; hr
  SECS="${SECS:-600}"
  phase_bidi || return 1
  # extra checks specific to a long run
  if grep -qiE "session.*(lost|timeout|closed)|client.*disconnect|reset" "$AGENT_LOG"; then
    red "  FAIL: agent logged a session loss / client disconnect during soak:"
    grep -iE "session.*(lost|timeout|closed)|client.*disconnect|reset" "$AGENT_LOG" | tail
    return 1
  fi
  grn "  OK: no agent-side session loss during ${SECS}s soak"
  return 0
}

case "$PHASE" in
  session)   phase_session ;;
  uni)       phase_session && phase_uni ;;
  bidi)      phase_session && phase_uni && phase_bidi ;;
  endurance) phase_session && phase_uni && phase_endurance ;;
  all)       phase_session && phase_uni && phase_bidi ;;
  *) red "unknown phase '$PHASE' (session|uni|bidi|endurance|all)"; exit 2 ;;
esac
rc=$?
hr
[ $rc -eq 0 ] && grn "PHASE '$PHASE' PASS" || red "PHASE '$PHASE' FAIL (rc=$rc)"
exit $rc
