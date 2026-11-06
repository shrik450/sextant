#!/usr/bin/env bash
#
# Times reading a review of ordinary size: moving between files, scrolling, switching modes,
# the overview and stepping through commits.

#######################################
# Prints a script command once per line, a number of times.
# Arguments:
#   How many times, then the command.
#######################################
repeat() {
  local n=$1 i
  shift
  for ((i = 0; i < n; i++)); do echo "$*"; done
}

#######################################
# Reads the work review (the agent branch against origin/main) the way a reviewer does.
# Globals:
#   SCENARIO_DIR, FIX
#######################################
scenario_reading() {
  fixture work
  local run="$SCENARIO_DIR/run"
  mkdir -p "$run"
  cat > "$run/script.txt" <<EOF
timeopen $FIX/work
sleep 3000
mark reading-start
measure 20 menu Next File
measure 10 menu Previous File
$(repeat 8 menu Next File)
measure 40 key w
measure 40 key j
$(repeat 8 menu Previous File)
measure 100 scroll 40
measure 100 scroll -40
measure 2 menu Side by Side
measure 40 scroll 40
measure 2 menu Unified
measure 2 menu Mark File as Reviewed
measure 1 menu All Changes
sleep 500
measure 100 scroll 40
measure 10 menu Next File
measure 1 menu Side by Side
measure 1 menu Unified
measure 2 menu Mark File as Reviewed
measure 3 menu Older Commit
measure 2 menu Newer Commit
measure 1 menu All Commits
mark reading-end
sleep 1000
quit
EOF
  launch "$run" --probe --timeout 300
  emit open_content_ms "$(opened "$run" content)"
  emit open_settled_ms "$(opened "$run" settled)"
  emit_measured "$run" next_file "menu Next File" 1 frame:median frame:p90 settled:median settled:p90
  emit_measured "$run" previous_file "menu Previous File" 1 frame:p90 settled:p90
  emit_measured "$run" caret_word "key w" 1 frame:max
  emit_measured "$run" caret_line "key j" 1 frame:max
  emit_measured "$run" file_scroll "scroll 40" 1 frame:median frame:max
  emit_measured "$run" side_by_side "menu Side by Side" 1 frame:max settled:max
  emit_measured "$run" side_by_side_scroll "scroll 40" 2 frame:max
  emit_measured "$run" unified "menu Unified" 1 frame:max settled:max
  emit_measured "$run" mark_reviewed "menu Mark File as Reviewed" 1 frame:max settled:max
  emit_measured "$run" all_changes "menu All Changes" 1 frame:max settled:max
  emit_measured "$run" overview_scroll "scroll 40" 3 frame:median frame:p90 frame:max
  emit_measured "$run" overview_next_file "menu Next File" 2 frame:p90 settled:p90
  emit_measured "$run" overview_side_by_side "menu Side by Side" 2 frame:max settled:max
  emit_measured "$run" overview_mark_reviewed "menu Mark File as Reviewed" 2 frame:max settled:max
  emit_measured "$run" older_commit "menu Older Commit" 1 settled:median settled:max
  emit_measured "$run" newer_commit "menu Newer Commit" 1 settled:max
  emit_measured "$run" all_commits "menu All Commits" 1 settled:max
  emit_main_thread "$run" reading-start reading-end
}
