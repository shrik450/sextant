#!/usr/bin/env bash
#
# Measures Go to Anything: indexing definitions, the time from each key to its results, and
# opening again with the index saved.

#######################################
# Opens Go to Anything on a review, waits for its definitions, types a query a key at a time
# and then all at once, and does it again in a second launch that finds the index saved.
# Globals:
#   SCENARIO_DIR
# Arguments:
#   Checkout, review spec ("" for the default), query, index timeout in seconds.
#######################################
measure_goto() {
  local repo=$1 spec=$2 query=$3 limit=$4 run pass c
  for pass in cold warm; do
    run="$SCENARIO_DIR/$pass"
    mkdir -p "$run"
    cat > "$run/script.txt" <<EOF
timeopen $repo $spec
sleep 2000
mark index-start
menu Go to Anything…
waitindex $((limit * 1000))
mark index-end
sleep 2000
mark typing-start
jumptype $query
mark typing-end
key esc
sleep 500
menu Go to Anything…
sleep 1000
mark burst-start
jumpburst $query
mark burst-end
key esc
sleep 500
quit
EOF
    launch "$run" --probe --timeout $((limit + 120))
    emit "${pass}_index_ms" "$(logged "$run" INDEXED INDEXED)"
    emit "${pass}_definitions" "$(logged "$run" INDEXED ms)"
    c=$(cost_between "$run" index-start index-end)
    emit_cost "${pass}_index" "$c" cpu_ms git_cpu_ms fp_peak_mb max_stall_ms
    emit "${pass}_index_footprint_mb" "$(awk -v a="$(mark_mb "$run" index-start)" -v b="$(mark_mb "$run" typing-start)" 'BEGIN { if (a != "" && b != "") print b - a }')"
    [[ $pass == warm ]] && continue
    emit definitions_file_mb "$(du -m "$repo/.git/sextant/definitions.json" 2>/dev/null | cut -f1)"
    emit key_frame_max "$(awk '/^JUMP / { split($0, h, "|"); if (match(h[1], /max [0-9.]+/)) print substr(h[1], RSTART + 4, RLENGTH - 4) }' "$run/run.log")"
    emit results_median "$(awk '/^JUMP / { split($0, h, "|"); if (match(h[2], /median [0-9.]+/)) print substr(h[2], RSTART + 7, RLENGTH - 7) }' "$run/run.log")"
    emit results_p90 "$(awk '/^JUMP / { split($0, h, "|"); if (match(h[2], /p90 [0-9.]+/)) print substr(h[2], RSTART + 4, RLENGTH - 4) }' "$run/run.log")"
    emit results_max "$(awk '/^JUMP / { split($0, h, "|"); if (match(h[2], /max [0-9.]+/)) print substr(h[2], RSTART + 4, RLENGTH - 4) }' "$run/run.log")"
    emit burst_results_ms "$(logged "$run" JUMPBURST results)"
    c=$(cost_between "$run" typing-start typing-end)
    emit cpu_per_key_ms "$(awk -v c="$(pick "$c" cpu_ms)" -v n="${#query}" 'BEGIN { printf "%.0f", c / n }')"
    emit_cost typing "$c" max_stall_ms
  done
}

#######################################
# Go to Anything on the work review, at ghostty's size.
# Globals:
#   FIX
#######################################
scenario_goto_work() {
  fixture work
  measure_goto "$FIX/work" "" renderthread 120
}

#######################################
# Go to Anything on Linux's last 30 commits, with every definition in the kernel.
# Globals:
#   FIX
#######################################
scenario_goto_linux() {
  fixture linux
  measure_goto "$FIX/linux" HEAD~30..HEAD kmalloc_node 600
}
