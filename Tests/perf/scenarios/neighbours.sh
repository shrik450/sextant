#!/usr/bin/env bash
#
# Reads a small file beside pathological ones, to check that preparing the next file to step to
# stays within a budget instead of parsing whatever lies next to it.

#######################################
# Opens longline.swift in the patho fixture, whose neighbours in the diff are megaline.swift,
# million.c and minified.min.js, stays there, then steps back one file.
# Globals:
#   SCENARIO_DIR, FIX
#######################################
scenario_neighbours() {
  fixture patho
  local run="$SCENARIO_DIR/run" c
  mkdir -p "$run"
  cat > "$run/script.txt" <<EOF
timeopen $FIX/patho HEAD~1..HEAD
sleep 2000
menu Go to Anything…
jumptype longline.swift
key return
mark beside
sleep 15000
mark beside-end
menu Previous File
mark back
sleep 10000
mark back-end
quit
EOF
  launch "$run" --probe --timeout 90 --max-mb 4096
  emit finished "$(finished "$run" && echo 1 || echo 0)"
  local beside back
  beside=$(mark_ns "$run" beside)
  [[ -z $beside ]] && return
  c=$(cost "$run" "$((beside + 2000000000))" "$(mark_ns "$run" beside-end)")
  emit beside_footprint_growth_mb "$(awk -v a="$(mark_mb "$run" beside)" -v p="$(pick "$c" fp_peak_mb)" 'BEGIN { if (a != "" && p != "") print p - a }')"
  emit_cost beside "$c" cpu_ms
  back=$(mark_ns "$run" back)
  [[ -z $back ]] && return
  c=$(cost "$run" "$((back + 2000000000))" "$(mark_ns "$run" back-end)")
  emit_cost back "$c" cpu_ms
}
