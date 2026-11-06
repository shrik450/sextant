#!/usr/bin/env bash
#
# Measures a 300,000-file repository: opening a review of a large commit, marking a file
# reviewed, and what one edit in the checkout costs.

#######################################
# Opens synth's last commit and marks a file reviewed, then reviews its uncommitted changes
# while one file is edited every 4 seconds.
# Globals:
#   SCENARIO_DIR, FIX
#######################################
scenario_synth() {
  fixture synth
  local run="$SCENARIO_DIR/commit"
  mkdir -p "$run"
  cat > "$run/script.txt" <<EOF
timeopen $FIX/synth HEAD~1..HEAD
sleep 2000
mark commit-start
measure 2 menu Mark File as Reviewed
measure 1 menu All Changes
measure 2 menu Mark File as Reviewed
mark commit-end
quit
EOF
  launch "$run" --probe --timeout 300
  emit open_content_ms "$(opened "$run" content)"
  emit open_settled_ms "$(opened "$run" settled)"
  emit_measured "$run" mark_reviewed "menu Mark File as Reviewed" 1 frame:max settled:max
  emit_measured "$run" all_changes "menu All Changes" 1 frame:max settled:max
  emit_measured "$run" overview_mark_reviewed "menu Mark File as Reviewed" 2 frame:max settled:max
  emit_main_thread "$run" commit-start commit-end

  run="$SCENARIO_DIR/edits"
  mkdir -p "$run"
  cat > "$run/script.txt" <<EOF
timeopen $FIX/synth
watch $run/states.txt
sleep 3000
mark edits-start
sleep 600000
EOF
  launch "$run" --probe --timeout 300 --driver "bash \"\$PERF_TESTS/drivers/edits.sh\" \"$FIX/synth\" d000/s00/f00001.c 5 4"
  phase_costs "$run"
  emit_over_phases "$run" edit_converge_ms converge_ms
  emit_over_phases "$run" edit_correct correct
  emit_over_phases "$run" edit_total_cpu_ms total_cpu_ms
  emit_over_phases "$run" edit_cpu_ms cpu_ms
  emit_over_phases "$run" edit_git_cpu_ms git_cpu_ms
  emit_over_phases "$run" edit_gits gits
  emit_over_phases "$run" edit_max_stall_ms max_stall_ms
}
