#!/usr/bin/env bash
#
# Measures the Linux kernel checkout: opening a review of its last 30 commits, reading it,
# refreshing it, and what one edit in the checkout costs.

#######################################
# Opens Linux's last 30 commits and reads them, then reviews its uncommitted changes while one
# file is edited every 5 seconds.
# Globals:
#   SCENARIO_DIR, FIX
#######################################
scenario_linux() {
  fixture linux
  local run="$SCENARIO_DIR/commits" c
  mkdir -p "$run"
  cat > "$run/script.txt" <<EOF
timeopen $FIX/linux HEAD~30..HEAD
sleep 3000
mark reading-start
measure 10 menu Next File
measure 2 menu Mark File as Reviewed
measure 1 menu Side by Side
measure 1 menu Unified
measure 1 menu All Changes
sleep 500
measure 100 scroll 40
measure 2 menu Mark File as Reviewed
measure 1 menu Side by Side
measure 1 menu Unified
measure 3 menu Older Commit
measure 2 menu Newer Commit
measure 1 menu All Commits
mark reading-end
sleep 2000
mark refresh-start
measure 3 menu Refresh
mark refresh-end
sleep 1000
quit
EOF
  launch "$run" --probe --timeout 400
  emit open_window_ms "$(opened "$run" window)"
  emit open_content_ms "$(opened "$run" content)"
  emit open_settled_ms "$(opened "$run" settled)"
  emit_measured "$run" next_file "menu Next File" 1 frame:p90 settled:p90
  emit_measured "$run" mark_reviewed "menu Mark File as Reviewed" 1 frame:max settled:max
  emit_measured "$run" side_by_side "menu Side by Side" 1 frame:max settled:max
  emit_measured "$run" all_changes "menu All Changes" 1 frame:max settled:max
  emit_measured "$run" overview_scroll "scroll 40" 1 frame:p90 frame:max
  emit_measured "$run" overview_mark_reviewed "menu Mark File as Reviewed" 2 frame:max settled:max
  emit_measured "$run" overview_side_by_side "menu Side by Side" 2 frame:max settled:max
  emit_measured "$run" older_commit "menu Older Commit" 1 settled:median settled:max
  emit_measured "$run" all_commits "menu All Commits" 1 settled:max
  emit_measured "$run" refresh "menu Refresh" 1 settled:median
  emit_main_thread "$run" reading-start reading-end
  c=$(cost_between "$run" refresh-start refresh-end)
  emit_cost refresh "$c" gits git_cpu_ms cpu_ms

  run="$SCENARIO_DIR/edits"
  mkdir -p "$run"
  cat > "$run/script.txt" <<EOF
timeopen $FIX/linux
watch $run/states.txt
sleep 5000
mark edits-start
sleep 600000
EOF
  launch "$run" --probe --timeout 300 --driver "bash \"\$PERF_TESTS/drivers/edits.sh\" \"$FIX/linux\" kernel/fork.c 4 5"
  emit worktree_open_content_ms "$(opened "$run" content)"
  phase_costs "$run"
  emit_over_phases "$run" edit_converge_ms converge_ms
  emit_over_phases "$run" edit_correct correct
  emit_over_phases "$run" edit_total_cpu_ms total_cpu_ms
  emit_over_phases "$run" edit_cpu_ms cpu_ms
  emit_over_phases "$run" edit_git_cpu_ms git_cpu_ms
  emit_over_phases "$run" edit_gits gits
  emit_over_phases "$run" edit_max_stall_ms max_stall_ms
  fixture_git -C "$FIX/linux" checkout -q -- kernel/fork.c
}
