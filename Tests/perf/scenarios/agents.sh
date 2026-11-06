#!/usr/bin/env bash
#
# Reviews the work checkout while agents edit, build and run git in it, and checks that the
# window comes to show exactly what git says, and how soon and at what cost.

#######################################
# Runs the agents driver beside the app, which records every change to the review it shows.
# Globals:
#   SCENARIO_DIR, FIX
#######################################
scenario_agents() {
  fixture work
  local run="$SCENARIO_DIR/run"
  mkdir -p "$run"
  cat > "$run/script.txt" <<EOF
timeopen $FIX/work
watch $run/states.txt
sleep 2000
mark agents-start
sleep 600000
EOF
  launch "$run" --probe --timeout 400 --driver 'bash "$PERF_TESTS/drivers/agents.sh"'
  phase_costs "$run"
  emit_each_phase "$run" converge_ms correct gap_max_ms gits git_cpu_ms cpu_ms max_stall_ms fp_growth_mb
  local c
  c=$(cost "$run" "$(mark_ns "$run" agents-start)" "$(awk '{ print $3 }' "$run/phases.txt" | tail -1)")
  emit_cost run "$c" max_stall_ms stalls_gt50 stalls_gt16 fp_peak_mb fp_end_mb gits git_cpu_ms cpu_ms
}
