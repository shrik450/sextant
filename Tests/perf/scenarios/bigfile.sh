#!/usr/bin/env bash
#
# Times moving through a 400-file change that includes a 30,000-line file, where some names are
# used thousands of times.

#######################################
# Moves the caret from name to name in the large file, where boxing every use of the name at
# the caret is the work, then from file to file, then through All Changes.
# Globals:
#   SCENARIO_DIR, FIX
#######################################
scenario_bigfile() {
  fixture bigfile
  local run="$SCENARIO_DIR/run"
  mkdir -p "$run"
  cat > "$run/script.txt" <<EOF
timeopen $FIX/bigfile HEAD~1..HEAD
sleep 300
mark bigfile-start
measure 40 key w
measure 30 menu Next File
measure 10 menu Previous File
measure 1 menu All Changes
measure 30 scroll 40
mark bigfile-end
quit
EOF
  launch "$run" --probe --timeout 180
  emit open_content_ms "$(opened "$run" content)"
  emit_measured "$run" caret_word "key w" 1 frame:median frame:max
  emit_measured "$run" next_file "menu Next File" 1 frame:median settled:median
  emit_measured "$run" previous_file "menu Previous File" 1 frame:median
  emit_measured "$run" all_changes "menu All Changes" 1 frame:max
  emit_measured "$run" overview_scroll "scroll 40" 1 frame:median frame:max
  emit_main_thread "$run" bigfile-start bigfile-end
}
