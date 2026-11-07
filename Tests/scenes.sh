#!/usr/bin/env bash
#
# Plays scenes that once went wrong in Sextant, and fails when the app doesn't come through one
# as it should.
#
# A crash scene plays against a ghostty checkout in the glass look, in light and in dark, and
# passes when the app reaches its end. A checked scene makes the repositories it needs and passes
# when what the app reports during the scene is right. The app runs behind the windows in use,
# one scene at a time under the GUI lock the benchmarks share. What each scene leaves, such as
# its script, log, state dumps and the gits the app ran, is in .build/scenes/<scene>.
#
# Usage: Tests/scenes.sh [--app <Sextant.app>] <ghostty checkout> [scene...]   (inside `nix develop`)
#   --app  play the scenes with this app, such as a release, instead of building one
#   scene  the scenes to play (default all); `list` lists them
#
# Settings:
#   SEXTANT_SCENES_BUNDLE  bundle ID for the app built (default com.shrikanthup.Sextant.scenes)
#   SEXTANT_PERF_LOCK      the GUI lock folder (default <main checkout>/scratch/gui-lock)

set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work="$here/.build/scenes"
app="$work/Sextant.app"
built=1
if [[ ${1:-} == --app ]]; then
  app=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
  built=0
  shift 2
fi
ghostty=$(cd "$1" && pwd)
shift
bundle_id=${SEXTANT_SCENES_BUNDLE:-com.shrikanthup.Sextant.scenes}
main_checkout=$(cd "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)
lock=${SEXTANT_PERF_LOCK:-$main_checkout/scratch/gui-lock}
real_git=$(command -v git)
scenes=(page symlink find reload close base status shared showall columns rename read endings removed)
failed=0
holding_lock=0

#######################################
# Builds the release app with its own bundle ID, so it keeps its own settings.
#######################################
build_app() {
  swift build -c release --product SextantApp >/dev/null
  swift build -c release --product sextant >/dev/null
  bash "$here/bundle.sh" "$(swift build -c release --show-bin-path)" "$work" "$real_git" "$SEXTANT_SYNTAX" >/dev/null
  plutil -replace CFBundleIdentifier -string "$bundle_id" "$app/Contents/Info.plist"
  plutil -remove CFBundleURLTypes "$app/Contents/Info.plist"
  codesign --force --sign - "$app" 2>/dev/null
}

#######################################
# Writes the git the app runs in a scene: it logs each command line to $SCENE_GIT_LOG, and
# waits $SCENE_GREP_DELAY seconds before a grep when that's set, so a scene can act while a
# search runs.
#######################################
write_git() {
  cat > "$work/git" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SCENE_GIT_LOG"
if [[ -n $SCENE_GREP_DELAY && " $* " == *" grep "* ]]; then sleep "$SCENE_GREP_DELAY"; fi
exec "$SCENE_GIT" "$@"
EOF
  chmod +x "$work/git"
}

#######################################
# Releases the GUI lock if this script holds it.
# Globals:
#   holding_lock, lock
#######################################
release_lock() {
  if ((holding_lock)); then
    rmdir "$lock" 2>/dev/null || true
    holding_lock=0
  fi
}
trap release_lock EXIT

#######################################
# Runs the app on a script under the GUI lock, behind the windows in use, until it quits.
# Globals:
#   app, bundle_id, lock, real_git, work
# Arguments:
#   The folder to run in, holding script.txt; the log goes to run.log and the gits to git.log.
#   Seconds before the app is killed (default 120).
#   Seconds each grep waits first (default none).
#######################################
run_app() {
  local dir=$1 limit=${2:-120} grep_delay=${3:-}
  rm -f "$dir/run.log" "$dir/git.log" "$dir/stderr.txt"
  touch "$dir/git.log"
  until mkdir "$lock" 2>/dev/null; do sleep 5; done
  holding_lock=1
  defaults delete "$bundle_id" >/dev/null 2>&1 || true
  (sleep "$limit" && pkill -f "$app/Contents/MacOS/Sextant") &
  local watchdog=$!
  open -n -g -W -a "$app" --stderr "$dir/stderr.txt" --env "SEXTANT_GIT=$work/git" --env "SCENE_GIT=$real_git" \
    --env "SCENE_GIT_LOG=$dir/git.log" --env "SCENE_GREP_DELAY=$grep_delay" \
    --args --automation "$dir/script.txt" --log "$dir/run.log" --background
  kill "$watchdog" 2>/dev/null || true
  defaults delete "$bundle_id" >/dev/null 2>&1 || true
  release_lock
}

#######################################
# Makes an empty folder for a scene and prints its path.
# Arguments:
#   Scene name.
#######################################
scene_dir() {
  rm -rf "${work:?}/$1"
  mkdir -p "$work/$1"
  echo "$work/$1"
}

#######################################
# Runs git as the fixtures need it: with a fixed identity, and without signing.
#######################################
g() {
  "$real_git" -c commit.gpgsign=false -c user.name=Scenes -c user.email=scenes@example.com "$@"
}

#######################################
# Prints one value from a state dump.
# Arguments:
#   The dump, then the key path (such as caret or panes.0.title).
#######################################
value() {
  plutil -extract "$2" raw -o - "$1" 2>/dev/null || echo "(none)"
}

#######################################
# Reports one check of a scene, and remembers a failure.
# Globals:
#   failed
# Arguments:
#   Scene name, what was checked, then 0 if it held.
#   What was seen and what was expected, for a check that didn't hold.
#######################################
check() {
  if [[ $3 == 0 ]]; then
    printf '%-10s ok      %s\n' "$1" "$2"
  else
    printf '%-10s FAILED  %s: saw %s, expected %s (see %s)\n' "$1" "$2" "$4" "$5" "$work/$1"
    failed=1
  fi
}

#######################################
# Checks that a value is what it should be.
# Arguments:
#   Scene name, what was checked, the value seen, and the value expected.
#######################################
expect() {
  local ok=1
  [[ $3 == "$4" ]] && ok=0
  check "$1" "$2" "$ok" "$3" "$4"
}

#######################################
# Prints how many gits a scene's app had run when the script wrote a count file.
# Arguments:
#   The scene folder, then the count file's name.
#######################################
gits_at() {
  tr -d ' ' < "$1/$2"
}

#######################################
# Plays page.zig opening through Go to Anything, which once crashed glass, in light and in dark.
#######################################
scene_page() {
  local dir appearance repo
  dir=$(scene_dir page)
  repo="$dir/ghostty"
  g init -q "$repo"
  echo "$ghostty/.git/objects" > "$repo/.git/objects/info/alternates"
  g -C "$repo" -c advice.detachedHead=false checkout -q a573781c6
  for appearance in light dark; do
    mkdir -p "$dir/$appearance"
    cat > "$dir/$appearance/script.txt" <<EOF
defaults look glass
open $repo a573781c6^..a573781c6
resize 1500 950
appearance $appearance
wait
sleep 1500
menu Go to Anything…
type terminal/page.zig
sleep 800
key return
wait
sleep 1500
log END
quit
EOF
    run_app "$dir/$appearance"
    local ok=1
    grep -qx END "$dir/$appearance/run.log" 2>/dev/null && ok=0
    check page "opening page.zig in $appearance" "$ok" "no END in run.log" "the scene to finish"
  done
}

#######################################
# Opens a repository through a symbolic link: marking a file reviewed writes only the app's own
# state, which mustn't refresh the review, and editing a tracked Cargo.lock must.
#######################################
scene_symlink() {
  local dir repo f
  dir=$(scene_dir symlink)
  repo="$dir/repo"
  mkdir -p "$repo"
  g init -q -b main "$repo"
  for f in a b c; do printf 'one\ntwo\n' > "$repo/$f.txt"; done
  printf 'version = 4\n' > "$repo/Cargo.lock"
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  for f in a b c; do printf 'three\n' >> "$repo/$f.txt"; done
  ln -s "$repo" "$dir/link"
  cat > "$dir/script.txt" <<EOF
open $dir/link
sleep 2000
sh wc -l < $dir/git.log > $dir/gits-opened
menu Mark File as Reviewed
sleep 2500
sh wc -l < $dir/git.log > $dir/gits-marked
sh printf 'version = 5\n' > $repo/Cargo.lock
sleep 2500
sh wc -l < $dir/git.log > $dir/gits-edited
quit
EOF
  run_app "$dir"
  local opened marked edited
  opened=$(gits_at "$dir" gits-opened)
  marked=$(gits_at "$dir" gits-marked)
  edited=$(gits_at "$dir" gits-edited)
  expect symlink "gits after marking a file reviewed" "$((marked - opened))" 0
  local ok=1
  ((edited > marked)) && ok=0
  check symlink "gits after editing Cargo.lock" "$ok" "$((edited - marked))" "some"
}

#######################################
# Peeks at a definition while Find in Files searches, with every grep held up for two seconds:
# the search's results must still show.
#######################################
scene_find() {
  local dir repo
  dir=$(scene_dir find)
  repo="$dir/repo"
  mkdir -p "$repo"
  g init -q -b main "$repo"
  printf 'func alpha() -> Int {\n    1\n}\n' > "$repo/a.swift"
  printf 'func beta() -> Int {\n    alpha()\n}\n' > "$repo/b.swift"
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  printf 'func beta() -> Int {\n    alpha() + alpha()\n}\n' > "$repo/b.swift"
  cat > "$dir/script.txt" <<EOF
open $repo
sleep 1000
key w
menu Find in Files…
type alpha
nowait key return
menu Peek Definition
sleep 6000
key esc
dump $dir/after.json
quit
EOF
  run_app "$dir" 120 2
  local status
  status=$(value "$dir/after.json" searchStatus)
  local ok=1
  [[ $status == *" in "*" file"* ]] && ok=0
  check find "Find in Files results after a Peek" "$ok" "\"$status\"" "results"
}

#######################################
# Edits another file while one is read with Blame and Highlight Uses on: the file read must keep
# its caret, blame and highlighted uses.
#######################################
scene_reload() {
  local dir repo
  dir=$(scene_dir reload)
  repo="$dir/repo"
  mkdir -p "$repo"
  g init -q -b main "$repo"
  printf 'func alpha() -> Int {\n    let value = 1\n    return value + value\n}\n' > "$repo/a.swift"
  printf 'func beta() {}\n' > "$repo/b.swift"
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  printf 'func alpha() -> Int {\n    let value = 2\n    return value + value\n}\n' > "$repo/a.swift"
  printf 'func beta() { }\n' > "$repo/b.swift"
  cat > "$dir/script.txt" <<EOF
open $repo
sleep 1500
menu Blame
sleep 1500
key j
key w
menu Highlight Uses
sleep 1000
dump $dir/before.json
sh printf 'func beta() {  }\n' > $repo/b.swift
sleep 3000
dump $dir/after.json
quit
EOF
  run_app "$dir"
  local key
  for key in caret uses blame selection; do
    expect reload "$key after another file changed" "$(value "$dir/after.json" "$key")" "$(value "$dir/before.json" "$key")"
  done
  expect reload "uses highlighted before the change" "$(value "$dir/before.json" uses)" 4
}

#######################################
# Closes the window while Go to Anything indexes 5,000 files of 300 definitions each from cold:
# the indexing must stop.
#######################################
scene_close() {
  local dir repo
  dir=$(scene_dir close)
  repo="$dir/repo"
  mkdir -p "$repo/src"
  g init -q -b main "$repo"
  awk -v dir="$repo/src" 'BEGIN {
    for (f = 0; f < 5000; f++) {
      file = sprintf("%s/f%04d.swift", dir, f)
      for (i = 0; i < 300; i++) printf "func f%d_%d() -> Int { %d }\n", f, i, i > file
      close(file)
    }
  }'
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  printf 'func changed() {}\n' >> "$repo/src/f0000.swift"
  g -C "$repo" commit -qam change
  cat > "$dir/script.txt" <<EOF
open $repo HEAD^..HEAD
sleep 1000
nowait menu Go to Anything…
sleep 150
dump $dir/closing.json
mark closing
menu Close Pane
sleep 5000
mark closed
quit
EOF
  run_app "$dir"
  local indexing closing closed ok
  indexing=$(value "$dir/closing.json" indexing)
  ok=1
  [[ $indexing == */* ]] && ok=0
  check close "files indexed when the window closed" "$ok" "\"$indexing\"" "some of them"
  closing=$(cpu_at "$dir" closing)
  closed=$(cpu_at "$dir" closed)
  ok=1
  ((closed - closing < 500)) && ok=0
  check close "CPU ms in the 5 s after closing" "$ok" "$((closed - closing))" "under 500"
}

#######################################
# Prints the CPU time the app had used at a mark in its log, in milliseconds.
# Arguments:
#   The scene folder, then the mark's name.
#######################################
cpu_at() {
  awk -v m="MARK $2:" 'index($0, m) == 1 { for (i = 2; i <= NF; i++) if ($i == "CPU,") { print $(i - 2); exit } }' "$1/run.log"
}

#######################################
# Opens a branch whose saved base was deleted: the review must compare with the usual base.
#######################################
scene_base() {
  local dir repo common
  dir=$(scene_dir base)
  repo="$dir/repo"
  mkdir -p "$repo"
  g init -q -b main "$repo"
  printf 'a\n' > "$repo/a.txt"
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  g -C "$repo" checkout -q -b part1
  printf 'b\n' > "$repo/b.txt"
  g -C "$repo" add -A
  g -C "$repo" commit -qm part1
  g -C "$repo" checkout -q -b feature
  printf 'c\n' > "$repo/c.txt"
  g -C "$repo" add -A
  g -C "$repo" commit -qm feature1
  printf 'd\n' > "$repo/d.txt"
  g -C "$repo" add -A
  g -C "$repo" commit -qm feature2
  g -C "$repo" checkout -q main
  g -C "$repo" branch -q -D part1
  common=$(cd "$repo/.git" && pwd -P)
  cat > "$dir/script.txt" <<EOF
sh defaults write $bundle_id bases -dict-add "$common|branch:feature" part1
sleep 1000
open $repo feature
sleep 2000
dump $dir/after.json
quit
EOF
  run_app "$dir"
  expect base "base" "$(value "$dir/after.json" base)" main
  expect base "subtitle" "$(value "$dir/after.json" subtitle)" "3 commits since main  ·  3 files"
}

#######################################
# Opens a repository with a linked worktree whose index is damaged: the worktree must be listed
# as one whose status git can't give.
#######################################
scene_status() {
  local dir repo
  dir=$(scene_dir status)
  repo="$dir/repo"
  mkdir -p "$repo"
  g init -q -b main "$repo"
  printf 'a\n' > "$repo/a.txt"
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  printf 'b\n' >> "$repo/a.txt"
  g -C "$repo" worktree add -q "$dir/linked"
  printf 'not an index' > "$repo/.git/worktrees/linked/index"
  cat > "$dir/script.txt" <<EOF
open $repo
sleep 2000
dump $dir/after.json
quit
EOF
  run_app "$dir"
  expect status "worktrees without a status" "$(value "$dir/after.json" statusFailures.0)" "$(cd "$dir/linked" && pwd -P)"
}

#######################################
# Writes a 600-line b.swift and commits it, then changes lines 300 and 500 in the worktree, so
# its diff is two hunks with unchanged lines before, between and after them.
# Arguments:
#   The repository.
#######################################
write_long_file() {
  seq 1 600 | awk '{ print "let value" $1 " = " $1 }' > "$1/b.swift"
  g -C "$1" add -A
  g -C "$1" commit -qm "long file"
  seq 1 600 | awk '$1 == 300 || $1 == 500 { print "let value" $1 " = -" $1; next } { print "let value" $1 " = " $1 }' > "$1/b.swift"
}

#######################################
# Prints a value from a panes dump.
# Arguments:
#   The scene folder, the dump's name, the pane's index, then the key.
#######################################
pane() {
  value "$1/$2.json" "panes.$3.$4"
}

#######################################
# Prints the index of the focused pane in a panes dump.
# Arguments:
#   The scene folder, then the dump's name.
#######################################
focused() {
  local i
  for i in 0 1 2 3 4 5; do
    [[ $(pane "$1" "$2" "$i" focused) == true ]] && { echo "$i"; return; }
  done
  echo 0
}

#######################################
# Prints the rows of a pane in a panes dump, as JSON.
# Arguments:
#   The scene folder, the dump's name, then the pane's index.
#######################################
pane_rows() {
  plutil -extract "panes.$3.rows" json -o - "$1/$2.json" 2>/dev/null || echo "(none)"
}

#######################################
# Shows All Changes beside b.swift opened whole, unfolded, and opened again in a third pane: the
# overview must go on showing the hunks it laid out, with its caret and its notes on the lines it
# shows, and each file pane must keep its own folds. Once the overview lays out again, it shows
# b.swift whole, numbered right, folded as a file pane first shows it and not as another pane
# unfolded it, and with unchanged lines shown, every line of it.
#######################################
scene_shared() {
  local dir repo
  dir=$(scene_dir shared)
  repo="$dir/repo"
  mkdir -p "$repo"
  g init -q -b main "$repo"
  printf 'a1\na2\na3\n' > "$repo/a.txt"
  printf 'c1\nc2\nc3\n' > "$repo/c.txt"
  write_long_file "$repo"
  printf 'a1\na2 changed\na3\n' > "$repo/a.txt"
  printf 'c1\nc2 changed\nc3\n' > "$repo/c.txt"
  cat > "$dir/script.txt" <<EOF
defaults readerMode overview
open $repo
wait
menu Next File
key j
key j
key j
key j
panes $dir/start.json
menu Go to Anything…
type b.swift
key cmd+return
wait
sleep 1000
panes $dir/opened.json
menu Show Nearby Unchanged Lines
wait
panes $dir/unfolded.json
menu Go to Anything…
type b.swift
key cmd+return
wait
sleep 1000
panes $dir/third.json
menu Previous Pane
menu Previous Pane
wait
render $dir/overview.png
note From the overview
wait
dump $dir/noted.json
panes $dir/after-note.json
quit
EOF
  run_app "$dir"
  local dump p
  for dump in start opened unfolded third after-note; do
    for p in 0 1 2; do
      [[ $(pane "$dir" "$dump" "$p" title) == "(none)" ]] && continue
      expect shared "rows unlike their lines in pane $p ($dump)" "$(pane "$dir" "$dump" "$p" mismatched)" 0
    done
  done
  expect shared "overview caret after the file panes" "$(pane "$dir" after-note 0 caret)" "$(pane "$dir" start 0 caret)"
  expect shared "note added from the overview" "$(value "$dir/noted.json" notes.0.title)" "$(pane "$dir" start 0 caret)"
  expect shared "overview gaps once it lays out again" "$(pane "$dir" after-note 0 gaps)" 0
  expect shared "overview folds once it lays out again" "$(pane "$dir" after-note 0 folds)" "$(pane "$dir" opened 1 folds)"
  expect shared "folds after unfolding one" "$(pane "$dir" unfolded 1 folds)" "$(($(pane "$dir" opened 1 folds) - 1))"
  expect shared "folds in a third pane on the file" "$(pane "$dir" third 2 folds)" "$(pane "$dir" opened 1 folds)"
  rm -rf "$repo/.git/sextant"
  mkdir -p "$dir/all"
  cat > "$dir/all/script.txt" <<EOF
defaults readerMode overview
open $repo
wait
menu Show Unchanged Lines
menu Next File
key j
key j
key j
key j
panes $dir/all/start.json
menu Go to Anything…
type b.swift
key cmd+return
wait
sleep 1000
menu Show Nearby Unchanged Lines
wait
menu Previous Pane
wait
note From the overview with unchanged lines
wait
dump $dir/all/noted.json
panes $dir/all/reloaded.json
menu Show Unchanged Lines
wait
panes $dir/all/hidden.json
quit
EOF
  run_app "$dir/all"
  local all="$dir/all" whole ok=1
  expect shared "gaps with unchanged lines shown, before b.swift is read" "$(pane "$all" start 0 gaps)" 2
  for dump in reloaded hidden; do
    expect shared "rows unlike their lines in the overview ($dump)" "$(pane "$all" "$dump" 0 mismatched)" 0
    expect shared "overview caret ($dump)" "$(pane "$all" "$dump" 0 caret)" "$(pane "$all" start 0 caret)"
  done
  whole=$(plutil -extract panes.0.rows json -o - "$all/reloaded.json")
  [[ $whole == *'" 150 let value150 = 150"'* && $whole == *'" 450 let value450 = 450"'* ]] && ok=0
  check shared "unchanged lines of b.swift, read whole, once the overview lays out again" "$ok" "rows without lines 150 and 450" "them"
  expect shared "gaps with unchanged lines shown, after b.swift is read" "$(pane "$all" reloaded 0 gaps)" 0
  expect shared "note from the overview with unchanged lines" "$(value "$all/noted.json" notes.0.title)" "$(pane "$all" start 0 caret)"
  expect shared "overview gaps once unchanged lines hide" "$(pane "$all" hidden 0 gaps)" 0
  expect shared "overview folds once unchanged lines hide" "$(pane "$all" hidden 0 folds)" "$(pane "$dir" opened 1 folds)"
}

#######################################
# Hides unchanged lines again with the caret on one of them: every run must fold, and the caret
# must move to the nearest line still shown.
#######################################
scene_showall() {
  local dir repo
  dir=$(scene_dir showall)
  repo="$dir/repo"
  mkdir -p "$repo"
  g init -q -b main "$repo"
  write_long_file "$repo"
  cat > "$dir/script.txt" <<EOF
open $repo
wait
menu Show Unchanged Lines
key j
key j
key j
key j
key j
key j
key j
key j
panes $dir/shown.json
menu Show Unchanged Lines
panes $dir/folded.json
quit
EOF
  run_app "$dir"
  expect showall "caret with unchanged lines shown" "$(pane "$dir" shown 0 caret)" "b.swift:307"
  expect showall "folds once hidden again" "$(pane "$dir" folded 0 folds)" 3
  expect showall "caret once hidden again" "$(pane "$dir" folded 0 caret)" "b.swift:303"
}

#######################################
# Reads changes that only add or only remove lines side by side: each must show both sides.
#######################################
scene_columns() {
  local dir repo
  dir=$(scene_dir columns)
  repo="$dir/repo"
  mkdir -p "$repo"
  g init -q -b main "$repo"
  printf 'one\ntwo\nthree\n' > "$repo/added.txt"
  printf 'one\ntwo\nthree\n' > "$repo/removed.txt"
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  printf 'one\ntwo\nmore\nthree\n' > "$repo/added.txt"
  printf 'one\nthree\n' > "$repo/removed.txt"
  cat > "$dir/script.txt" <<EOF
defaults diffMode split
open $repo
wait
panes $dir/added.json
menu Next File
wait
panes $dir/removed.json
quit
EOF
  run_app "$dir"
  expect columns "columns for added lines" "$(pane "$dir" added 0 columns)" 2
  expect columns "columns for removed lines" "$(pane "$dir" removed 0 columns)" 2
}

#######################################
# Reads a file renamed without changes and one whose mode alone changed: each must open with
# what changed above its lines, Jump to Definition must land in the renamed file, and All
# Changes must show what changed, not the lines, even once they're read.
#######################################
scene_rename() {
  local dir repo rows ok
  dir=$(scene_dir rename)
  repo="$dir/repo"
  mkdir -p "$repo"
  g init -q -b main "$repo"
  printf 'func helper() -> Int {\n    42\n}\n' > "$repo/lib.swift"
  printf 'let x = 1\n' > "$repo/main.swift"
  printf 'echo hi\n' > "$repo/run.sh"
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  g -C "$repo" mv lib.swift core.swift
  chmod +x "$repo/run.sh"
  printf 'let x = helper()\n' > "$repo/main.swift"
  cat > "$dir/script.txt" <<EOF
defaults readerMode file
open $repo
wait
panes $dir/renamed.json
menu Next File
wait
key j
wait
menu Jump to Definition
wait
sleep 500
panes $dir/jumped.json
menu Next File
wait
menu Next File
wait
panes $dir/mode.json
menu All Changes
wait
panes $dir/overview.json
quit
EOF
  run_app "$dir"
  expect rename "renamed file's rows" "$(pane_rows "$dir" renamed 0)" '["notice Renamed without changes"," 1 func helper() -> Int {"," 2     42"," 3 }"]'
  expect rename "caret after Jump to Definition" "$(pane "$dir" jumped "$(focused "$dir" jumped)" caret)" "core.swift:1"
  expect rename "mode change's rows" "$(pane_rows "$dir" mode "$(focused "$dir" mode)")" '["notice Mode changed from 100644 to 100755"," 1 echo hi"]'
  rows=$(pane_rows "$dir" overview "$(focused "$dir" overview)")
  ok=1
  [[ $rows == *'"header core.swift","notice Renamed without changes","header main.swift"'* && $rows != *'func helper'* ]] && ok=0
  check rename "renamed file in All Changes" "$ok" "$rows" "its header and notice only"
}

#######################################
# Reads one of two runs of changes with the same lines, then edits the file elsewhere twice, as
# an agent would, once before and once after marking it reviewed: only the run read must read,
# and the runs read or reviewed must stay read once the file changes elsewhere.
#######################################
scene_read() {
  local dir repo
  dir=$(scene_dir read)
  repo="$dir/repo"
  mkdir -p "$repo"
  g init -q -b main "$repo"
  printf 'func a() {\n    1\n}\n\nfunc b() {\n    2\n}\n' > "$repo/a.swift"
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  printf 'func a() {\n    guard ready else { return }\n    1\n}\n\nfunc b() {\n    guard ready else { return }\n    2\n}\n' > "$repo/a.swift"
  cat > "$dir/script.txt" <<EOF
open $repo
wait
menu Mark Change as Read
wait
dump $dir/one.json
sh printf '// one\n' >> $repo/a.swift
sleep 2500
wait
dump $dir/edited.json
menu Mark File as Reviewed
wait
sh { printf '// two\n'; cat $repo/a.swift; } > $dir/a.tmp && mv $dir/a.tmp $repo/a.swift
sleep 2500
wait
dump $dir/reviewed-edited.json
quit
EOF
  run_app "$dir"
  expect read "runs read after reading the first of two alike" "$(plutil -extract read json -o - "$dir/one.json" 2>/dev/null)" '[true,false]'
  expect read "file reviewed after reading one run of two" "$(value "$dir/one.json" files.0.reviewed)" false
  expect read "runs read once the file changes elsewhere" "$(plutil -extract read json -o - "$dir/edited.json" 2>/dev/null)" '[true,false,false]'
  expect read "runs read once a reviewed file changes elsewhere" "$(plutil -extract read json -o - "$dir/reviewed-edited.json" 2>/dev/null)" '[false,true,true,true]'
  expect read "file reviewed once it changes elsewhere" "$(value "$dir/reviewed-edited.json" files.0.reviewed)" false
}

#######################################
# Reads a change that only turns one CR LF line ending into LF, and one that adds the newline
# missing at the end of a file: each line must say how it ends, as the lines read the same.
#######################################
scene_endings() {
  local dir repo
  dir=$(scene_dir endings)
  repo="$dir/repo"
  mkdir -p "$repo"
  g init -q -b main "$repo"
  printf 'one\r\ntwo\r\nthree\r\n' > "$repo/dos.txt"
  printf 'a\nb' > "$repo/tail.txt"
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  printf 'one\r\ntwo\nthree\r\n' > "$repo/dos.txt"
  printf 'a\nb\n' > "$repo/tail.txt"
  cat > "$dir/script.txt" <<EOF
defaults readerMode file
open $repo
wait
panes $dir/dos.json
render $dir/dos.png
menu Next File
wait
panes $dir/tail.json
quit
EOF
  run_app "$dir"
  expect endings "rows of a line ending changed" "$(pane_rows "$dir" dos 0)" '[" 1 one","-2 two ⏎ CRLF","+2 two ⏎ LF"," 3 three"]'
  expect endings "rows of a newline added at the end" "$(pane_rows "$dir" tail 0)" '[" 1 a","-2 b ⏎ No newline at end of file","+2 b ⏎ LF"]'
}

#######################################
# Puts the caret on a removed line below an insertion that moves the lines after it: Next and
# Previous Definition must step from where the line was, not from the top of the file.
#######################################
scene_removed() {
  local dir repo
  dir=$(scene_dir removed)
  repo="$dir/repo"
  mkdir -p "$repo"
  g init -q -b main "$repo"
  printf 'func a() {\n    1\n}\nfunc b() {\n    let x = 1\n    let y = 2\n}\nfunc c() {\n    3\n}\n' > "$repo/a.swift"
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  printf '// one\n// two\n// three\nfunc a() {\n    1\n}\nfunc b() {\n    let x = 1\n}\nfunc c() {\n    3\n}\n' > "$repo/a.swift"
  cat > "$dir/script.txt" <<EOF
defaults readerMode file
open $repo
wait
menu Next Change
wait
sleep 500
dump $dir/removed.json
menu Next Definition
dump $dir/next.json
menu Next Change
wait
menu Previous Definition
dump $dir/previous.json
quit
EOF
  run_app "$dir"
  expect removed "caret on the removed line" "$(value "$dir/removed.json" caret)" "a.swift:6 (old):9"
  expect removed "caret after Next Definition" "$(value "$dir/next.json" caret)" "a.swift:10:6"
  expect removed "caret after Previous Definition" "$(value "$dir/previous.json" caret)" "a.swift:7:6"
}

if [[ ${1:-} == list ]]; then
  printf '%s\n' "${scenes[@]}"
  exit 0
fi
(($#)) && scenes=("$@")
mkdir -p "$work"
((built)) && build_app
bundle_id=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")
write_git
for s in "${scenes[@]}"; do "scene_$s"; done
exit "$failed"
