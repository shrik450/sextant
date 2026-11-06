#!/usr/bin/env bash
#
# Plays an agent beside the soak: appends to a tracked file every 2 seconds and commits every
# 30 appends. At each "checkpoint-<n>" mark, counts the app's view and layout objects with
# heap and records how long heap held the app suspended in $OUT/pauses.txt.
#
# Run by Tests/perf/lib/harness.sh's launch as a driver, with PID, LOG, OUT, FIX and GIT set.
# Writes $OUT/checkpoints.txt: "<n> <row views> <layout engines> <heap MB> <footprint MB>".

set -uo pipefail
source "$PERF_TESTS/lib/drive.sh"
export GIT_OPTIONAL_LOCKS=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Agent GIT_AUTHOR_EMAIL=agent@example.com GIT_COMMITTER_NAME=Agent GIT_COMMITTER_EMAIL=agent@example.com

#######################################
# Counts the app's row views and layout engines, and its heap, when a checkpoint is logged.
# Globals:
#   OUT, PID
# Arguments:
#   Checkpoint number.
#######################################
inspect() {
  local start end
  start=$(now_ns)
  /usr/bin/heap "$PID" > "$OUT/heap-$1.txt" 2>&1
  end=$(now_ns)
  echo "$start $end" >> "$OUT/pauses.txt"
  awk -v n="$1" -v fp="$(/usr/bin/footprint -p "$PID" 2>/dev/null | awk '/^ *phys_footprint:/ { print $2; exit }')" '
    /PillRowView|ClassicRowView/ && $1 ~ /^[0-9]+$/ { rows += $1 }
    / NSISEngine +ObjC/ { engines += $1 }
    /^All zones: [0-9]+ nodes \(/ { gsub(/[()]/, ""); bytes = $5 }
    END { printf "%s %d %d %.1f %s\n", n, rows, engines, bytes / 1048576, fp }' "$OUT/heap-$1.txt" >> "$OUT/checkpoints.txt"
}

wait_for 'MARK soak-start'
n=0 seen=0
until grep -q 'MARK soak-end' "$LOG"; do
  for c in $(grep -o 'MARK checkpoint-[0-9]*' "$LOG" | sed 's/.*-//'); do
    if ((c > seen)); then
      inspect "$c"
      seen=$c
    fi
  done
  echo "// soak $n" >> "$FIX/work/src/main.zig"
  n=$((n + 1))
  ((n % 30 == 0)) && "$GIT" -C "$FIX/work" commit -q -am "Soak $n"
  sleep 2
done
for c in $(grep -o 'MARK checkpoint-[0-9]*' "$LOG" | sed 's/.*-//'); do
  ((c > seen)) && inspect "$c" && seen=$c
done
kill "$PID"
