#!/usr/bin/env bash
#
# Turns what a run recorded into metrics. Sourced by Tests/perf/run.sh.
#
# A scenario emits "<scenario>\t<metric>\t<value>" lines into $SCENARIO_DIR/metrics.tsv, and
# run.sh checks them against budgets.tsv.

#######################################
# Records one metric of the running scenario.
# Globals:
#   SCENARIO, SCENARIO_DIR
# Arguments:
#   Metric name, then its value (empty for a measurement that didn't happen).
#######################################
emit() {
  printf '%s\t%s\t%s\n' "$SCENARIO" "$1" "${2:-}" >> "$SCENARIO_DIR/metrics.tsv"
}

#######################################
# Prints when a mark was logged, in unix nanoseconds.
# Arguments:
#   Run folder, mark name.
#######################################
mark_ns() {
  awk -v m="MARK $2:" 'index($0, m) == 1 { print $NF; exit }' "$1/run.log"
}

#######################################
# Prints what a run cost between two times, as cost.awk's key=value words.
# Arguments:
#   Run folder, start and end in unix nanoseconds.
#######################################
cost() {
  [[ -n $2 && -n $3 ]] || return 0
  awk -v lo="$2" -v hi="$3" -v run="$1" -f "$PERF_TESTS/lib/cost.awk" "$1/samples.txt"
}

#######################################
# Prints what a run cost between two marks.
# Arguments:
#   Run folder, first mark, second mark.
#######################################
cost_between() {
  cost "$1" "$(mark_ns "$1" "$2")" "$(mark_ns "$1" "$3")"
}

#######################################
# Picks one key's value out of cost's output.
# Arguments:
#   The key=value words, the key.
#######################################
pick() {
  tr ' ' '\n' <<<"$1" | awk -F= -v k="$2" '$1 == k { print $2; found = 1 } END { if (!found && k ~ /^gits_/) print 0 }'
}

#######################################
# Emits some keys of a cost as metrics named <prefix>_<key>.
# Arguments:
#   Prefix, the key=value words, then the keys.
#######################################
emit_cost() {
  local prefix=$1 words=$2 key
  shift 2
  for key in "$@"; do emit "${prefix}_$key" "$(pick "$words" "$key")"; done
}

#######################################
# Prints a statistic of a MEASURE line.
# Arguments:
#   Run folder, what was measured as the line says it ("menu Next File", "scroll 40"),
#   frame or settled, median, p90 or max, and which matching line (default 1).
#######################################
measured() {
  awk -v what="MEASURE $2 ×" -v part="$3" -v stat="$4" -v nth="${5:-1}" '
    index($0, what) == 1 && ++seen == nth {
      split($0, halves, "|")
      s = (part == "frame") ? halves[1] : halves[2]
      if (match(s, stat " [0-9.]+")) { v = substr(s, RSTART, RLENGTH); sub(/.* /, "", v); print v }
      exit
    }' "$1/run.log"
}

#######################################
# Emits a MEASURE line's frame and settled statistics as <name>_frame_<stat> and
# <name>_settled_<stat>.
# Arguments:
#   Run folder, metric name, what was measured, which matching line, then the statistics as
#   part:stat words, such as frame:p90 settled:median.
#######################################
emit_measured() {
  local run=$1 name=$2 what=$3 nth=$4 ps
  shift 4
  for ps in "$@"; do emit "${name}_${ps%%:*}_${ps##*:}" "$(measured "$run" "$what" "${ps%%:*}" "${ps##*:}" "$nth")"; done
}

#######################################
# Prints one of the times on a run's first OPEN line.
# Arguments:
#   Run folder, window, content or settled, and which OPEN line (default 1).
#######################################
opened() {
  awk -v part="$2" -v nth="${3:-1}" '
    /^OPEN / && ++seen == nth {
      if (match($0, part " [0-9.na]+")) { v = substr($0, RSTART, RLENGTH); sub(/.* /, "", v); if (v != "nan") print v }
      exit
    }' "$1/run.log"
}

#######################################
# Prints a number from the first log line starting with a prefix: the field after a label.
# Arguments:
#   Run folder, line prefix, label (the word before the number, or "" for the first number).
#######################################
logged() {
  awk -v pre="$2" -v label="$3" '
    index($0, pre) == 1 {
      n = split($0, f, /[ ,:]+/)
      for (i = 1; i <= n; i++) if ((label == "" && f[i] ~ /^[0-9.]+$/) || (label != "" && f[i] == label && i < n)) { print (label == "" ? f[i] : f[i + 1]); exit }
      exit
    }' "$1/run.log"
}

#######################################
# Says whether a run ended on its own.
# Arguments:
#   Run folder.
# Returns:
#   1 if the app timed out, was killed or never started.
#######################################
finished() {
  ! grep -qE '^(TIMEOUT|KILLED|app didn)' "$1/meta.txt"
}

#######################################
# Emits the main-thread stalls, footprint, CPU and git processes of a run between two marks,
# as run_<key>.
# Arguments:
#   Run folder, first mark, second mark.
#######################################
emit_main_thread() {
  local c
  c=$(cost_between "$1" "$2" "$3")
  emit_cost run "$c" max_stall_ms stalls_gt50 stalls_gt16 fp_peak_mb fp_end_mb cpu_ms git_cpu_ms gits
}

#######################################
# Writes <run>/phase-costs.txt: for each phase a driver recorded, one line of its converge.awk
# words and its cost from its start until the next phase began (or 3 s after it ended).
# Arguments:
#   Run folder holding states.txt and phases.txt.
#######################################
phase_costs() {
  local run=$1 phase start end next
  awk -v dir="$run" -f "$PERF_TESTS/lib/converge.awk" "$run/states.txt" > "$run/converge.txt"
  : > "$run/phase-costs.txt"
  while read -r phase start end; do
    next=$(awk -v p="$phase" 'found { print $2; exit } $1 == p { found = 1 }' "$run/phases.txt")
    [[ -z $next ]] && next=$((end + 3000000000))
    echo "$(grep "^$phase " "$run/converge.txt") $(cost "$run" "$start" "$next")" >> "$run/phase-costs.txt"
  done < "$run/phases.txt"
}

#######################################
# Emits the median, worst and least of one key over every line of phase-costs.txt, as
# <name>_median, <name>_max and <name>_min.
# Arguments:
#   Run folder, metric name, the key.
#######################################
emit_over_phases() {
  local metric value
  awk -v k="$3" '{ for (i = 2; i <= NF; i++) { split($i, kv, "="); if (kv[1] == k) print kv[2] } }' "$1/phase-costs.txt" |
    sort -n | awk -v name="$2" '{ v[NR] = $1 } END { if (NR) { print name "_median " v[int((NR + 1) / 2)]; print name "_max " v[NR]; print name "_min " v[1] } }' |
    while read -r metric value; do emit "$metric" "$value"; done
}

#######################################
# Emits some keys of each line of phase-costs.txt as <phase>_<key>.
# Arguments:
#   Run folder, then the keys.
#######################################
emit_each_phase() {
  local run=$1 line key
  shift
  while read -r line; do
    for key in "$@"; do emit "${line%% *}_$key" "$(pick "$line" "$key")"; done
  done < "$run/phase-costs.txt"
}

#######################################
# Prints the footprint in MB that a mark logged.
# Arguments:
#   Run folder, mark name.
#######################################
mark_mb() {
  awk -v m="MARK $2:" 'index($0, m) == 1 { for (i = 2; i <= NF; i++) if ($i ~ /^MB,?$/) { print $(i - 1); exit } }' "$1/run.log"
}
