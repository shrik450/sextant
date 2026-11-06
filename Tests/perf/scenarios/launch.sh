#!/usr/bin/env bash
#
# Times warm launches on the work checkout.

#######################################
# Prints the median of numbers, one per line on stdin.
#######################################
median() {
  sort -n | awk '{ v[NR] = $1 } END { if (NR) print v[int((NR + 1) / 2)] }'
}

#######################################
# Launches the app three times on work, after one launch to warm the caches, and records the
# median time until AppKit is up, the window shows, content shows and the window settles, with
# the CPU, git processes and footprint until three seconds after settling.
# Globals:
#   SCENARIO_DIR, FIX
#######################################
scenario_launch() {
  fixture work
  local i run c
  for i in 0 1 2 3; do
    run="$SCENARIO_DIR/run$i"
    mkdir -p "$run"
    printf 'mark start\ntimeopen %s\nmark opened\nsleep 3000\nmark idle\nquit\n' "$FIX/work" > "$run/script.txt"
    launch "$run" --timeout 60
    c=$(cost "$run" "$(awk '/^# start_realtime_ns/ { print $3 }' "$run/samples.txt")" "$(mark_ns "$run" idle)")
    ((i == 0)) && continue
    {
      echo "appkit_ms $(logged "$run" "MARK start" start)"
      echo "window_ms $(opened "$run" window)"
      echo "content_ms $(opened "$run" content)"
      echo "settled_ms $(opened "$run" settled)"
      echo "cpu_ms $(pick "$c" cpu_ms)"
      echo "git_cpu_ms $(pick "$c" git_cpu_ms)"
      echo "gits $(pick "$c" gits)"
      echo "peak_mb $(pick "$c" fp_lifetime_peak_mb)"
      echo "settled_footprint_mb $(pick "$c" fp_end_mb)"
    } >> "$SCENARIO_DIR/runs.txt"
  done
  local k
  for k in $(awk '{ print $1 }' "$SCENARIO_DIR/runs.txt" | awk '!seen[$0]++'); do
    emit "$k" "$(awk -v k="$k" '$1 == k { print $2 }' "$SCENARIO_DIR/runs.txt" | median)"
  done
}
