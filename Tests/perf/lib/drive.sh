#!/usr/bin/env bash
#
# Helpers for drivers, the scripts that play an agent beside the app: waiting for the app,
# writing files, recording phases and what git says the review should show.
#
# Drivers run with PID, LOG (automation log), OUT (run folder), FIX (fixtures) and GIT set.

#######################################
# Waits until the automation log has a line matching a pattern.
# Globals:
#   LOG
# Arguments:
#   An extended regular expression.
#######################################
wait_for() {
  until grep -q -E "$1" "$LOG" 2>/dev/null; do sleep 0.05; done
}

#######################################
# Prints the time in unix nanoseconds.
#######################################
now_ns() {
  local t=${EPOCHREALTIME/./}
  echo "${t}000"
}

#######################################
# Rewrites a file whole with one more line, as an agent's edit tool does: a new file renamed
# over the old one.
# Arguments:
#   The file, and a tag to write into it.
#######################################
rewrite() {
  awk -v tag="$2" 'NR == 3 { print "// edited by agent " tag } { print }' "$1" > "$1.agent-tmp" && mv "$1.agent-tmp" "$1"
}

#######################################
# Writes what git says the review of a checkout shows: one "<path>\t<added>\t<deleted>" line
# per file changed since a base, sorted by path, counting each untracked file's lines as added
# and binary files as 0 and 0.
# Arguments:
#   The checkout, the base revision, the file to write.
#######################################
truth() {
  local repo=$1 base=$2 out=$3
  {
    "$GIT" -C "$repo" diff -M --numstat -z "$base" -- | awk 'BEGIN { RS = "\0" }
      $0 == "" { next }
      {
        split($0, f, "\t"); a = (f[1] == "-" ? 0 : f[1]); d = (f[2] == "-" ? 0 : f[2]); p = f[3]
        if (p == "") { getline; getline p }
        print p "\t" a "\t" d
      }'
    "$GIT" -C "$repo" ls-files --others --exclude-standard -z | while IFS= read -r -d '' p; do
      printf '%s\t%s\t0\n' "$p" "$(wc -l < "$repo/$p" | tr -d ' ')"
    done
  } | LC_ALL=C sort > "$out"
}

#######################################
# Records a phase of agent work: when it began and ended, and what the review should show once
# it settles. Call it after waiting for the app to catch up, so asking git for the truth doesn't
# compete with the app while it does.
# Globals:
#   OUT
# Arguments:
#   Phase name, its start and end in unix nanoseconds, the checkout, the base revision.
#######################################
phase_done() {
  truth "$4" "$5" "$OUT/truth-$1.txt"
  echo "$1 $2 $3" >> "$OUT/phases.txt"
}
