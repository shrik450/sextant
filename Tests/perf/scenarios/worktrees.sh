#!/usr/bin/env bash
#
# Shows five worktrees of one repository in five panes while one of them changes, to check the
# cost follows the worktree that changed.

#######################################
# Opens work and four linked worktrees in five panes, then appends to and stages a file in one
# of them once a second for 20 seconds.
# Globals:
#   SCENARIO_DIR, FIX, GIT
#######################################
scenario_worktrees() {
  fixture work
  local w
  for w in 1 2 3 4; do fixture_git -C "$FIX/work" worktree add -q "$FIX/work-wt-$w" -b "agent-$w"; done
  local run="$SCENARIO_DIR/run" c
  mkdir -p "$run"
  {
    echo "timeopen $FIX/work"
    echo "sleep 2000"
    for w in 1 2 3 4; do
      printf 'menu Go to Anything…\njumptype build.zig\nkey cmd+return\nsleep 1500\nopen %s\n' "$FIX/work-wt-$w"
    done
    echo "sleep 5000"
    echo "mark panes-start"
    echo "sleep 10000"
    echo "mark panes-end"
    echo "mark churn-start"
    echo "sleep 20000"
    echo "mark churn-end"
    echo "sleep 3000"
    echo "dump $run/state.json"
    echo "quit"
  } > "$run/script.txt"
  launch "$run" --probe --timeout 200 --driver "source \"\$PERF_TESTS/lib/drive.sh\"
    wait_for 'MARK churn-start'
    for t in \$(seq 1 20); do
      echo \"// churn \$t\" >> \"$FIX/work-wt-2/src/main.zig\"
      GIT_OPTIONAL_LOCKS=0 \"\$GIT\" -C \"$FIX/work-wt-2\" add src/main.zig
      sleep 1
    done"
  emit panes "$(awk '/"panes" : \[/ { inside = 1; next } inside && /\]/ { print n + 0; exit } inside { n++ }' "$run/state.json" 2>/dev/null)"
  c=$(cost_between "$run" panes-start panes-end)
  emit_cost idle "$c" gits cpu_ms fp_end_mb
  c=$(cost_between "$run" churn-start churn-end)
  emit_cost churn "$c" gits git_cpu_ms cpu_ms max_stall_ms stalls_gt50
  local lo hi
  lo=$(mark_ns "$run" churn-start) hi=$(mark_ns "$run" churn-end)
  emit churn_status_elsewhere "$(awk -v lo="$lo" -v hi="$hi" -v changed="$FIX/work-wt-2" '
    $1 >= lo && $1 <= hi && / status / && $4 != changed { n++ } END { print n + 0 }' "$run/git.log")"
  emit churn_status_changed "$(awk -v lo="$lo" -v hi="$hi" -v changed="$FIX/work-wt-2" '
    $1 >= lo && $1 <= hi && / status / && $4 == changed { n++ } END { print n + 0 }' "$run/git.log")"
}
