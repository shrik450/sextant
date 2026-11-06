#!/usr/bin/env bash
#
# Navigates the work review 100 times beside an agent, counting view and layout objects and
# the footprint at fixed checkpoints, to show whether memory reaches a plateau.

#######################################
# Prints the soak's automation script: 100 cycles of navigation, each from the first changed
# file, with checkpoints after cycles 1, 25, 50, 75 and 100 that leave the app alone long
# enough for heap.
# Arguments:
#   The checkout.
#######################################
soak_script() {
  local i
  echo "timeopen $1"
  echo "sleep 3000"
  echo "mark soak-start"
  for i in $(seq 1 100); do
    echo "mark cycle-$i"
    echo "menu Find File…"
    echo "key return"
    echo "measure 5 menu Next File"
    echo "measure 5 menu Previous File"
    echo "measure 20 scroll 40"
    echo "measure 1 menu All Changes"
    echo "measure 20 scroll 40"
    echo "measure 1 menu Side by Side"
    echo "measure 1 menu Unified"
    echo "measure 1 menu Older Commit"
    echo "measure 1 menu Newer Commit"
    echo "measure 1 menu All Commits"
    echo "measure 3 key j"
    echo "sleep 1000"
    case $i in
      1 | 25 | 50 | 75 | 100)
        echo "sleep 2000"
        echo "mark checkpoint-$i"
        echo "sleep 20000"
        ;;
    esac
  done
  echo "mark soak-end"
  echo "sleep 600000"
}

#######################################
# Runs the soak and emits the object counts and footprint at the checkpoints.
# Globals:
#   SCENARIO_DIR, FIX
#######################################
scenario_soak() {
  fixture work
  local run="$SCENARIO_DIR/run" n rows engines heap fp c
  mkdir -p "$run"
  soak_script "$FIX/work" > "$run/script.txt"
  launch "$run" --probe --timeout 1500 --driver 'bash "$PERF_TESTS/drivers/soak.sh"'
  while read -r n rows engines heap fp; do
    emit "row_views_$n" "$rows"
    emit "layout_engines_$n" "$engines"
    emit "heap_mb_$n" "$heap"
    emit "footprint_mb_$n" "$(mark_mb "$run" "checkpoint-$n")"
  done < "$run/checkpoints.txt"
  emit footprint_drift_25_100_mb "$(awk -v a="$(mark_mb "$run" checkpoint-25)" -v b="$(mark_mb "$run" checkpoint-100)" 'BEGIN { if (a != "" && b != "") print b - a }')"
  emit heap_drift_25_100_mb "$(awk '$1 == 25 { a = $4 } $1 == 100 { b = $4 } END { if (a != "" && b != "") print b - a }' "$run/checkpoints.txt")"
  emit next_file_settled_first "$(measured "$run" "menu Next File" settled median 1)"
  emit next_file_settled_last "$(measured "$run" "menu Next File" settled median 100)"
  emit all_changes_settled_first "$(measured "$run" "menu All Changes" settled max 1)"
  emit all_changes_settled_last "$(measured "$run" "menu All Changes" settled max 100)"
  emit_main_thread "$run" soak-start soak-end
}
