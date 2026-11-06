#!/usr/bin/env bash
#
# Times edits to the overview of a 10,000-file review: marking a file reviewed, unfolding,
# adding a note, and zooming.

#######################################
# Opens the many review, shows All Changes, scrolls it, and changes it in each way a reviewer
# does.
# Globals:
#   SCENARIO_DIR, FIX
#######################################
scenario_overview() {
  fixture many
  local run="$SCENARIO_DIR/run"
  mkdir -p "$run"
  cat > "$run/script.txt" <<EOF
timeopen $FIX/many HEAD~1..HEAD
sleep 2000
mark overview-start
measure 1 menu All Changes
sleep 1000
measure 100 scroll 40
measure 2 menu Mark File as Reviewed
measure 2 menu Show Nearby Unchanged Lines
measure 2 note A note from the benchmark
measure 1 menu Bigger
measure 1 menu Smaller
measure 1 menu Side by Side
measure 1 menu Unified
mark overview-end
sleep 1000
quit
EOF
  launch "$run" --probe --timeout 300
  emit open_content_ms "$(opened "$run" content)"
  emit_measured "$run" all_changes "menu All Changes" 1 frame:max settled:max
  emit_measured "$run" scroll "scroll 40" 1 frame:median frame:p90 frame:max
  emit_measured "$run" mark_reviewed "menu Mark File as Reviewed" 1 frame:max settled:max
  emit_measured "$run" unfold "menu Show Nearby Unchanged Lines" 1 frame:max settled:max
  emit_measured "$run" note "note A note from the benchmark" 1 frame:max settled:max
  emit_measured "$run" bigger "menu Bigger" 1 frame:max settled:max
  emit_measured "$run" smaller "menu Smaller" 1 frame:max settled:max
  emit_measured "$run" side_by_side "menu Side by Side" 1 frame:max settled:max
  emit_measured "$run" unified "menu Unified" 1 frame:max settled:max
  emit_main_thread "$run" overview-start overview-end
}
