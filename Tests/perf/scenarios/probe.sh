#!/usr/bin/env bash
#
# Checks that the stall probe sees main-thread stalls, including one the app is killed in.

#######################################
# Blocks the main thread of a small program and then of the app, for 2 s and then until each
# is killed, and records what the probe saw.
# Globals:
#   PERF_WORK, SCENARIO_DIR, FIX
#######################################
scenario_probe() {
  local d="$SCENARIO_DIR/selftest" pid spid
  mkdir -p "$d"
  DYLD_INSERT_LIBRARIES="$PERF_WORK/libprobe.dylib" PROBE_OUT="$d/probe" PROBE_PING_MS=4 PROBE_LOG_MS=16 \
    "$PERF_WORK/stall" 300 2000 10000 > "$d/stall.out" &
  pid=$!
  "$PERF_WORK/psample" "$pid" 50 "" "$d/probe" > "$d/samples.txt" &
  spid=$!
  until grep -q "stall 10000" "$d/stall.out" 2>/dev/null; do sleep 0.05; done
  sleep 1.5
  kill -9 "$pid"
  wait "$spid" 2>/dev/null
  emit selftest_short_stall_ms "$(awk '$2 > 200 && $2 < 1000 { print $2; exit }' "$d/probe.stalls")"
  emit selftest_stall_ms "$(awk '$2 >= 1000 && $2 < 5000 { print $2; exit }' "$d/probe.stalls")"
  emit selftest_killed_stall_ms "$(awk '/^# probe-final/ { print $4 }' "$d/samples.txt")"

  fixture work
  local run="$SCENARIO_DIR/app"
  mkdir -p "$run"
  cat > "$run/script.txt" <<EOF
timeopen $FIX/work
sleep 1000
mark stall-start
stall 2000
mark stall-end
sleep 500
mark kill
stall 10000
EOF
  launch "$run" --probe --timeout 60 --driver 'source "$PERF_TESTS/lib/drive.sh"; wait_for "MARK kill"; sleep 2; kill -9 $PID'
  local c
  c=$(cost_between "$run" stall-start stall-end)
  emit app_stall_ms "$(pick "$c" max_stall_ms)"
  c=$(cost "$run" "$(mark_ns "$run" kill)" "$(($(mark_ns "$run" kill) + 30000000000))")
  emit app_killed_stall_ms "$(pick "$c" unrecovered_ms)"
}
