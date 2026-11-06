#!/usr/bin/env bash
#
# Opens each pathological file of the patho review on its own: a 1 MB line, a million lines
# and a 10 MB minified bundle.

#######################################
# Opens one file through Go to Anything, watches the app for 15 seconds, then goes to a small
# file and checks that the work stops. Each file gets a fresh app, killed after 90 seconds or
# past 4 GB.
# Globals:
#   SCENARIO_DIR, FIX
# Arguments:
#   Metric prefix, Go to Anything query.
#######################################
open_patho() {
  local name=$1 query=$2 run="$SCENARIO_DIR/$1" c jump observed left
  mkdir -p "$run"
  cat > "$run/script.txt" <<EOF
timeopen $FIX/patho HEAD~1..HEAD
sleep 2000
menu Go to Anything…
jumptype $query
mark jump
measure 1 key return
mark shown
sleep 15000
mark observed
menu Go to Anything…
jumptype crlf.txt
key return
mark left
sleep 5000
mark after
quit
EOF
  launch "$run" --probe --timeout 90 --max-mb 4096
  emit "${name}_finished" "$(finished "$run" && echo 1 || echo 0)"
  emit "${name}_show_frame_ms" "$(measured "$run" "key return" frame max)"
  emit "${name}_show_settled_ms" "$(measured "$run" "key return" settled max)"
  jump=$(mark_ns "$run" jump)
  [[ -z $jump ]] && return
  observed=$(mark_ns "$run" observed)
  c=$(cost "$run" "$jump" "${observed:-$((jump + 120000000000))}")
  emit "${name}_footprint_growth_mb" "$(awk -v a="$(mark_mb "$run" jump)" -v p="$(pick "$c" fp_peak_mb)" 'BEGIN { if (a != "" && p != "") print p - a }')"
  emit_cost "${name}_open" "$c" cpu_ms max_stall_ms
  left=$(mark_ns "$run" left)
  if [[ -n $left ]]; then
    c=$(cost "$run" "$((left + 200000000))" "$(mark_ns "$run" after)")
    emit_cost "${name}_after_leaving" "$c" cpu_ms
  fi
}

#######################################
# Opens the 1 MB line, the million-line file and the minified bundle in turn.
#######################################
scenario_patho() {
  fixture patho
  open_patho megaline megaline.swift
  open_patho million million.c
  open_patho minified minified.min.js
}
