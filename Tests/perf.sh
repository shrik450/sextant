#!/usr/bin/env bash
#
# Measures how fast Revue opens and moves through a large review, and fails when a measurement
# goes over its budget.
#
# Builds a release app and a repository with a 400-file change, including a 30,000-line file,
# then drives the app through its automation script behind the windows in use, so it doesn't
# take focus. Times are the app's own work for each step: "frame" is handling it, laying out and
# drawing it, and "settled" adds the sidebars that follow a turn of the run loop later.
#
# Usage: Tests/perf.sh (inside `nix develop`)

set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work="$here/.build/perf"
repo="$work/repo"
app="$work/Revue.app"
log="$work/run.log"

#######################################
# Writes a Swift file of small functions, some of which change between versions.
# Arguments:
#   Number of functions.
#   Version: 1 for the original, 2 for the changed one.
#   File to write.
#######################################
swift_file() {
  awk -v n="$1" -v v="$2" 'BEGIN {
    print "import Foundation\n"
    for (j = 0; j < n; j++) {
      changed = v == 2 && (j % 25 == 5)
      printf "/// Scales input %d.\nfunc f%d(_ x: Int) -> Int {\n    let y = x + %d\n    return y * %d\n}\n\n", j, j, j, changed ? 3 : 2
    }
  }' > "$3"
}

#######################################
# Builds the repository: one commit with every file, then one that changes them all.
#######################################
make_repo() {
  rm -rf "$repo"
  mkdir -p "$repo"
  cd "$repo"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=Perf GIT_AUTHOR_EMAIL=perf@example.com GIT_COMMITTER_NAME=Perf GIT_COMMITTER_EMAIL=perf@example.com
  git init -q -b main .
  for v in 1 2; do
    for i in $(seq 0 399); do
      mkdir -p "src/m$((i / 10))"
      swift_file 75 "$v" "src/m$((i / 10))/file$i.swift"
    done
    swift_file 5000 "$v" src/big.swift
    git add -A
    git commit -q -m "Version $v"
  done
  cd "$here"
}

#######################################
# Builds the release app with its own bundle ID, so it keeps its own settings.
#######################################
build_app() {
  swift build -c release --product RevueApp >/dev/null
  swift build -c release --product revue >/dev/null
  bash "$here/bundle.sh" "$(swift build -c release --show-bin-path)" "$work" "$(command -v git)" "$REVUE_SYNTAX" >/dev/null
  plutil -replace CFBundleIdentifier -string dev.shrik450.Revue.perf "$app/Contents/Info.plist"
  plutil -remove CFBundleURLTypes "$app/Contents/Info.plist"
  codesign --force --sign - "$app" 2>/dev/null
}

#######################################
# Runs the measurements and prints them.
#######################################
measure() {
  cat > "$work/script.txt" <<EOF
timeopen $repo HEAD~1..HEAD
sleep 300
measure 30 menu Next File
measure 10 menu Previous File
measure 1 menu All Changes
measure 30 scroll 40
quit
EOF
  rm -f "$log"
  defaults delete dev.shrik450.Revue.perf >/dev/null 2>&1 || true
  (sleep 180 && pkill -f "$app/Contents/MacOS/Revue") &
  local watchdog=$!
  open -n -g -W -a "$app" --args --automation "$work/script.txt" --log "$log" --background
  kill "$watchdog" 2>/dev/null || true
  grep -E '^(OPEN|MEASURE)' "$log"
}

#######################################
# Checks one measurement against its budget.
# Arguments:
#   Name to report.
#   Pattern for the log line.
#   Field to read: "content" for opening, or "frame" or "settled" for a step.
#   Budget in milliseconds.
# Returns:
#   1 if the measurement is missing or over budget.
#######################################
check() {
  local line value
  line=$(grep -F "$2" "$log" | head -1)
  value=$(sed -nE "s/.*$3( median)? ([0-9.]+).*/\2/p" <<<"$line")
  if [[ -z $value ]]; then
    printf '%-28s missing\n' "$1"
    return 1
  fi
  if awk -v v="$value" -v b="$4" 'BEGIN { exit !(v <= b) }'; then
    printf '%-28s %8s ms  (budget %s)\n' "$1" "$value" "$4"
  else
    printf '%-28s %8s ms  OVER budget %s\n' "$1" "$value" "$4"
    return 1
  fi
}

mkdir -p "$work"
make_repo
build_app
measure
echo
failed=0
check "First file on screen" "OPEN" content 400 || failed=1
check "Next file" "menu Next File" frame 8 || failed=1
check "Previous file" "menu Previous File" frame 8 || failed=1
check "Next file, sidebars too" "menu Next File" settled 16 || failed=1
check "All Changes" "menu All Changes" frame 100 || failed=1
check "Scrolling All Changes" "scroll 40" frame 8 || failed=1
exit "$failed"
