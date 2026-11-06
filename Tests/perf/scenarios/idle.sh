#!/usr/bin/env bash
#
# Measures what the app costs when nobody uses it.

#######################################
# Emits a phase's wake-ups and CPU per second and its git processes.
# Arguments:
#   Run folder, phase name: the marks are <name>-start and <name>-end.
#######################################
emit_idle() {
  local c
  c=$(cost_between "$1" "$2-start" "$2-end")
  emit "${2}_wakeups_per_s" "$(pick "$c" wk_per_s)"
  emit "${2}_cpu_ms_per_s" "$(awk -v c="$(pick "$c" cpu_ms)" -v w="$(pick "$c" wall_ms)" 'BEGIN { if (w > 0) printf "%.2f", c * 1000 / w }')"
  emit "${2}_gits" "$(pick "$c" gits)"
}

#######################################
# Opens work and leaves it alone: shown behind other windows, while unrelated files elsewhere
# on disk are written 20 times a second, and hidden. The probe stays off, since it wakes the
# app itself.
# Globals:
#   SCENARIO_DIR, FIX
#######################################
scenario_idle() {
  fixture work
  local run="$SCENARIO_DIR/run"
  mkdir -p "$run"
  rm -rf "$FIX/elsewhere"
  cat > "$run/script.txt" <<EOF
timeopen $FIX/work
sleep 10000
mark shown-start
sleep 15000
mark shown-end
mark unrelated-start
sleep 12000
mark unrelated-end
menu Hide Sextant
sleep 3000
mark hidden-start
sleep 15000
mark hidden-end
quit
EOF
  launch "$run" --timeout 120 --driver 'source "$PERF_TESTS/lib/drive.sh"
    wait_for "MARK unrelated-start"
    mkdir -p "$FIX/elsewhere"
    for i in $(seq 1 200); do echo "artifact $i" > "$FIX/elsewhere/out$((i % 50)).txt"; sleep 0.05; done'
  rm -rf "$FIX/elsewhere"
  emit_idle "$run" shown
  emit_idle "$run" unrelated
  emit_idle "$run" hidden
}
