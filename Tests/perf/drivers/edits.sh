#!/usr/bin/env bash
#
# Appends a line to one tracked file at a steady pace while Sextant reviews the checkout's
# uncommitted changes, recording each edit as a phase. Ends the app when done.
#
# Usage: edits.sh <checkout> <file> <edits> <seconds between edits>
# Run by Tests/perf/lib/harness.sh's launch as a driver, with PID, LOG, OUT and GIT set.

set -uo pipefail
source "$PERF_TESTS/lib/drive.sh"
repo=$1 file=$2 edits=$3 pause=$4
export GIT_OPTIONAL_LOCKS=0

wait_for "MARK edits-start"
for i in $(seq 1 "$edits"); do
  t=$(now_ns)
  echo "// edit $i" >> "$repo/$file"
  end=$(now_ns)
  sleep "$pause"
  phase_done "edit$i" "$t" "$end" "$repo" HEAD
done
kill "$PID"
