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
scenes=(page symlink find reload close base status shared showall columns rename read advance endings removed notes reference harness fields frames reopen lookups drop slowdrop paneclose large)
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
# search runs (or fails it when that's `fail`), and $SCENE_SLOW_DELAY seconds before any git
# run in $SCENE_SLOW_REPO, so one repository loads slowly.
#######################################
write_git() {
  cat > "$work/git" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SCENE_GIT_LOG"
if [[ $SCENE_GREP_DELAY == fail && " $* " == *" grep "* ]]; then echo "fatal: the scene fails every grep" >&2; exit 128; fi
if [[ -n $SCENE_GREP_DELAY && $SCENE_GREP_DELAY != fail && " $* " == *" grep "* ]]; then sleep "$SCENE_GREP_DELAY"; fi
if [[ -n $SCENE_SLOW_REPO && $(pwd -P)/ == "$SCENE_SLOW_REPO"/* ]]; then sleep "$SCENE_SLOW_DELAY"; fi
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
#   Seconds each grep waits first, or `fail` to fail each (default none).
#   A repository whose gits each wait first, then how many seconds (default none).
#######################################
run_app() {
  local dir=$1 limit=${2:-120} grep_delay=${3:-} slow_repo=${4:-} slow_delay=${5:-}
  rm -f "$dir/run.log" "$dir/git.log" "$dir/stderr.txt"
  touch "$dir/git.log"
  until mkdir "$lock" 2>/dev/null; do sleep 5; done
  holding_lock=1
  defaults delete "$bundle_id" >/dev/null 2>&1 || true
  (sleep "$limit" && pkill -f "$app/Contents/MacOS/Sextant") &
  local watchdog=$!
  open -n -g -W -a "$app" --stderr "$dir/stderr.txt" --env "SEXTANT_GIT=$work/git" --env "SCENE_GIT=$real_git" \
    --env "SCENE_GIT_LOG=$dir/git.log" --env "SCENE_GREP_DELAY=$grep_delay" \
    --env "SCENE_SLOW_REPO=$slow_repo" --env "SCENE_SLOW_DELAY=$slow_delay" \
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
# and the runs read or reviewed must stay read once the file changes elsewhere. Once the work is
# committed, nothing starts from that file any more, and what was read in it must go.
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
sh git -C $repo -c commit.gpgsign=false -c user.name=Scenes -c user.email=scenes@example.com commit -qam work
sleep 2500
wait
quit
EOF
  run_app "$dir"
  expect read "runs read after reading the first of two alike" "$(plutil -extract read json -o - "$dir/one.json" 2>/dev/null)" '[true,false]'
  expect read "file reviewed after reading one run of two" "$(value "$dir/one.json" files.0.reviewed)" false
  expect read "runs read once the file changes elsewhere" "$(plutil -extract read json -o - "$dir/edited.json" 2>/dev/null)" '[true,false,false]'
  expect read "runs read once a reviewed file changes elsewhere" "$(plutil -extract read json -o - "$dir/reviewed-edited.json" 2>/dev/null)" '[false,true,true,true]'
  expect read "file reviewed once it changes elsewhere" "$(value "$dir/reviewed-edited.json" files.0.reviewed)" false
  expect read "files with changes read once the work is committed" "$(plutil -convert json -o - "$repo/.git/sextant/read.json" 2>/dev/null)" '{}'
  expect read "files reviewed once the work is committed" "$(plutil -convert json -o - "$repo/.git/sextant/reviewed.json" 2>/dev/null)" '{}'
}

#######################################
# Marks changes read and files reviewed in five files with two runs each, moving on after
# marking and then not. With it on, reading a run must go to the next unread run, reading the
# last one and reviewing a file to the next unreviewed file; with it off, all must stay put.
#######################################
scene_advance() {
  local dir repo f
  dir=$(scene_dir advance)
  repo="$dir/repo"
  mkdir -p "$repo"
  g init -q -b main "$repo"
  for f in a b c d e; do printf 'func a() {\n    1\n}\n\nfunc b() {\n    2\n}\n' > "$repo/$f.swift"; done
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  for f in a b c d e; do printf 'func a() {\n    guard ready else { return }\n    1\n}\n\nfunc b() {\n    guard ready else { return }\n    2\n}\n' > "$repo/$f.swift"; done
  cat > "$dir/script.txt" <<EOF
defaults readerMode file
open $repo
wait
menu Mark Change as Read
wait
dump $dir/on-read.json
menu Mark Change as Read
wait
dump $dir/on-last-read.json
menu Mark File as Reviewed
wait
dump $dir/on-reviewed.json
defaults advancesAfterMarking 0
menu Mark Change as Read
wait
dump $dir/off-read.json
menu Mark File as Reviewed
wait
dump $dir/off-reviewed.json
menu Next File
wait
menu Mark Change as Read
wait
menu Next Change
wait
menu Mark Change as Read
wait
dump $dir/off-last-read.json
quit
EOF
  run_app "$dir"
  expect advance "on: caret on the next unread run" "$(caret_line "$dir/on-read.json")" "a.swift:7"
  expect advance "on: file reviewed after reading its last run" "$(value "$dir/on-last-read.json" files.0.reviewed)" true
  expect advance "on: next unreviewed file after reading the last run" "$(value "$dir/on-last-read.json" currentChange)" "b.swift"
  expect advance "on: next unreviewed file after reviewing" "$(value "$dir/on-reviewed.json" currentChange)" "c.swift"
  expect advance "off: run read" "$(plutil -extract read json -o - "$dir/off-read.json" 2>/dev/null)" '[true,false]'
  expect advance "off: caret stays on the run read" "$(caret_line "$dir/off-read.json")" "c.swift:2"
  expect advance "off: file reviewed" "$(value "$dir/off-reviewed.json" files.2.reviewed)" true
  expect advance "off: same file after reviewing" "$(value "$dir/off-reviewed.json" currentChange)" "c.swift"
  expect advance "off: file reviewed after reading its last run" "$(value "$dir/off-last-read.json" files.3.reviewed)" true
  expect advance "off: same file after reading the last run" "$(caret_line "$dir/off-last-read.json")" "d.swift:7"
}

#######################################
# Prints the file and line of the caret in a state dump, without its column.
# Arguments:
#   The dump.
#######################################
caret_line() {
  local caret
  caret=$(value "$1" caret)
  echo "${caret%:*}"
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

#######################################
# Adds a note of three lines on the first removed line of a change read side by side: the note
# must follow the line it's on, and every row after it must stay level with its other side.
#######################################
scene_notes() {
  local dir repo
  dir=$(scene_dir notes)
  repo="$dir/repo"
  mkdir -p "$repo"
  g init -q -b main "$repo"
  printf 'l1\nl2\nl3\nl4\nl5\nl6\n' > "$repo/a.txt"
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  printf 'l1\nL2\nL3\nL4\nl5\nl6\n' > "$repo/a.txt"
  cat > "$dir/script.txt" <<EOF
defaults diffMode split
defaults readerMode file
open $repo
wait
note First\nsecond\nthird
wait
panes $dir/noted.json
quit
EOF
  run_app "$dir"
  expect notes "rows beside a note of three lines" "$(pane_rows "$dir" noted 0)" '[" 1 l1","+2 L2","note First\nsecond\nthird","+3 L3","+4 L4"," 5 l5"," 6 l6"]'
  expect notes "rows out of level with their other side" "$(pane "$dir" noted 0 misaligned)" 0
}

#######################################
# Selects an unchanged line and the removed lines after it, and adds a note: the note must name
# all three lines, numbered as they were.
#######################################
scene_reference() {
  local dir repo
  dir=$(scene_dir reference)
  repo="$dir/repo"
  mkdir -p "$repo"
  g init -q -b main "$repo"
  printf 'a\nb\nc\nd\n' > "$repo/a.txt"
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  printf 'a\nd\n' > "$repo/a.txt"
  cat > "$dir/script.txt" <<EOF
defaults diffMode unified
defaults readerMode file
open $repo
wait
key k
key shift+v
key j
key j
dump $dir/selected.json
note Across the removal
wait
dump $dir/noted.json
quit
EOF
  run_app "$dir"
  expect reference "rows selected" "$(value "$dir/selected.json" selectionRows)" 3
  expect reference "note on an unchanged line and removed ones" "$(value "$dir/noted.json" notes.0.title)" "a.txt:1-3 (removed)"
}

#######################################
# Checks the script driving the app: menu shortcuts behind the windows in use, cmd++, and
# waiting, which must wait for the window's own loads, not another window's, and for its
# colours.
#######################################
scene_harness() {
  local dir small slow heavy f
  dir=$(scene_dir harness)
  small="$dir/small"
  slow="$dir/slow"
  heavy="$dir/heavy"
  for repo in "$small" "$slow" "$heavy"; do
    mkdir -p "$repo"
    g init -q -b main "$repo"
    printf 'one\n' > "$repo/a.txt"
    g -C "$repo" add -A
    g -C "$repo" commit -qm base
  done
  for f in a b c; do printf 'func %s() {}\n' "$f" > "$small/$f.swift"; done
  printf 'two\n' >> "$slow/a.txt"
  awk 'BEGIN { for (i = 0; i < 40000; i++) printf "let value%d = compute(%d, \"text %d\") + other.value%d\n", i, i, i, i }' > "$heavy/heavy.swift"
  slow=$(cd "$slow" && pwd -P)
  cat > "$dir/script.txt" <<EOF
defaults readerMode file
open $small
wait
key shift+l
dump $dir/moved.json
key cmd++
dump $dir/bigger.json
key cmd+k
dump $dir/jump.json
key esc
sh (for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.4; echo \$i >> $small/a.swift; done) >/dev/null 2>&1 &
open $slow
dump $dir/slow.json
open $heavy
dump $dir/heavy.json
quit
EOF
  run_app "$dir" 120 "" "$slow" 0.4
  expect harness "file after Shift-L behind other windows" "$(value "$dir/moved.json" currentChange)" b.swift
  expect harness "font size after cmd++" "$(value "$dir/bigger.json" fontSize)" 13
  expect harness "Go to Anything after cmd+k" "$(value "$dir/jump.json" jumpShown)" true
  expect harness "slow repository's files when its open is waited for" "$(value "$dir/slow.json" files.0.path)" a.txt
  expect harness "colours when a heavy file's open is waited for" "$(value "$dir/heavy.json" settled)" true
}

#######################################
# Types letters that are also commands' shortcuts into the file filter and into Go to
# Anything: the letters must go into the fields, and the commands must stay in the menus and in
# Go to Anything. Copy Symbol Name must offer the definition around a blank line.
#######################################
scene_fields() {
  local dir repo f
  dir=$(scene_dir fields)
  repo="$dir/repo"
  mkdir -p "$repo"
  g init -q -b main "$repo"
  for f in a b c; do printf 'func %s() {\n    let one = 1\n}\n' "$f" > "$repo/$f.swift"; done
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  for f in a b c; do printf 'func %s() {\n    let one = 1\n\n    let two = 2\n}\n' "$f" > "$repo/$f.swift"; done
  cat > "$dir/script.txt" <<EOF
defaults readerMode file
defaults diffMode unified
open $repo
wait
dump $dir/blank.json
menu Go to Anything…
key u
dump $dir/jump.json
key esc
menu Find File…
key u
dump $dir/filter.json
quit
EOF
  run_app "$dir"
  expect fields "caret on the blank line" "$(value "$dir/blank.json" caret)" a.swift:3:1
  expect fields "Copy Symbol Name on a blank line in a function" "$(has_command "$dir/blank.json" "Copy Symbol Name")" yes
  expect fields "filter text after typing u" "$(value "$dir/filter.json" filterText)" u
  expect fields "file after typing u in the filter" "$(value "$dir/filter.json" currentChange)" a.swift
  expect fields "Next Unreviewed File while the filter has the keyboard" "$(has_command "$dir/filter.json" "Next Unreviewed File")" yes
  expect fields "Go to Anything's text after typing u" "$(value "$dir/jump.json" jumpQuery)" u
  expect fields "file after typing u in Go to Anything" "$(value "$dir/jump.json" currentChange)" a.swift
}

#######################################
# Prints yes if a state dump lists a command among those enabled, as Go to Anything offers them.
# Arguments:
#   The dump, then the command's title.
#######################################
has_command() {
  if plutil -extract commands json -o - "$1" 2>/dev/null | grep -qF "\"$2\""; then echo yes; else echo no; fi
}

#######################################
# Opens two repositories: each window must save its frame under its own repository's name, as
# AppKit lets only one open window save under a name. A window manager may move and resize the
# windows as they open, so the scene checks what's saved rather than where the windows are.
#######################################
scene_frames() {
  local dir one two repo
  dir=$(scene_dir frames)
  one="$dir/one"
  two="$dir/two"
  for repo in "$one" "$two"; do
    mkdir -p "$repo"
    g init -q -b main "$repo"
    printf 'a\n' > "$repo/a.txt"
    g -C "$repo" add -A
    g -C "$repo" commit -qm base
    printf 'b\n' >> "$repo/a.txt"
  done
  one=$(cd "$one/.git" && pwd -P)
  two=$(cd "$two/.git" && pwd -P)
  cat > "$dir/script.txt" <<EOF
open ${one%/.git}
wait
dump $dir/one.json
open ${two%/.git}
wait
resize 1100 700
dump $dir/two.json
sh defaults read $bundle_id > $dir/defaults.txt
quit
EOF
  run_app "$dir"
  expect frames "first window's saved frame" "$(value "$dir/one.json" frameName)" "SextantWindow $one"
  expect frames "second window's saved frame" "$(value "$dir/two.json" frameName)" "SextantWindow $two"
  expect frames "frames saved" "$(grep -c '"NSWindow Frame SextantWindow' "$dir/defaults.txt")" 2
}

#######################################
# Opens a repository whose gits are slow, then opens a branch of it while the window still
# starts: the window must review the branch, with its refs.
#######################################
scene_reopen() {
  local dir repo
  dir=$(scene_dir reopen)
  repo="$dir/repo"
  mkdir -p "$repo"
  g init -q -b main "$repo"
  printf 'a\n' > "$repo/a.txt"
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  g -C "$repo" checkout -q -b feature
  printf 'b\n' > "$repo/b.txt"
  g -C "$repo" add -A
  g -C "$repo" commit -qm feature
  g -C "$repo" checkout -q main
  printf 'c\n' >> "$repo/a.txt"
  repo=$(cd "$repo" && pwd -P)
  cat > "$dir/script.txt" <<EOF
nowait open $repo
sleep 200
open $repo feature
wait
sleep 1000
wait
dump $dir/after.json
quit
EOF
  run_app "$dir" 120 "" "$repo" 0.3
  expect reopen "subject once both opens are done" "$(value "$dir/after.json" subject)" branch:feature
}

#######################################
# Looks names up when git fails, and when the answer comes after the reader moved on: Find
# References must say what failed, and a Peek or a file's history that comes once another file
# or no pane shows must not pop up.
#######################################
scene_lookups() {
  local dir repo slow
  dir=$(scene_dir lookups)
  repo="$dir/repo"
  slow="$dir/slow"
  for r in "$repo" "$slow"; do
    mkdir -p "$r"
    g init -q -b main "$r"
    printf 'func alpha() -> Int {\n    1\n}\n' > "$r/a.swift"
    printf 'func beta() -> Int {\n    alpha()\n}\n' > "$r/b.swift"
    g -C "$r" add -A
    g -C "$r" commit -qm base
    printf 'func alpha() -> Int {\n    alpha() + 2\n}\n' > "$r/a.swift"
    printf 'func beta() -> Int {\n    alpha() + 3\n}\n' > "$r/b.swift"
  done
  mkdir -p "$dir/failing" "$dir/late"
  cat > "$dir/failing/script.txt" <<EOF
defaults readerMode file
open $repo
wait
key w
menu Find References
wait
dump $dir/failing/after.json
quit
EOF
  run_app "$dir/failing" 120 fail
  expect lookups "Find References when git fails" "$(value "$dir/failing/after.json" searchStatus)" "fatal: the scene fails every grep"
  slow=$(cd "$slow" && pwd -P)
  cat > "$dir/late/script.txt" <<EOF
defaults readerMode file
open $slow
wait
key w
nowait menu Peek Definition
sleep 100
menu Next File
sleep 2500
dump $dir/late/peek.json
nowait menu File History
sleep 100
menu Previous File
sleep 2500
dump $dir/late/history.json
menu Go to Anything…
type b.swift
key cmd+return
wait
key w
nowait menu Peek Definition
sleep 100
menu Close Pane
sleep 2500
dump $dir/late/closed.json
log END
quit
EOF
  run_app "$dir/late" 120 "" "$slow" 1
  expect lookups "popovers after a Peek answered once another file shows" "$(value "$dir/late/peek.json" popovers)" 0
  expect lookups "menus after a history answered once another file shows" "$(grep -c '^MENU History' "$dir/late/run.log")" 0
  expect lookups "popovers after a Peek answered once its pane closed" "$(value "$dir/late/closed.json" popovers)" 0
  expect lookups "scene finished" "$(grep -cx END "$dir/late/run.log")" 1
}

#######################################
# Makes a repository of 5,000 Swift files and commits a change to one, for scenes that need
# indexing to take a while.
# Arguments:
#   The repository's folder.
#######################################
make_many_files() {
  local repo=$1
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
}

#######################################
# Prints how many of the app's own child processes a scene's `sh` listing holds, leaving out
# the shell that listed them and the batch reader that stays.
# Arguments:
#   The listing file.
#######################################
children_in() {
  grep -v -e ' sh$' -e 'cat-file' "$1" | grep -c .
}

#######################################
# Leaves a review while its definitions are indexed: indexing must stop with it.
#######################################
scene_drop() {
  local dir repo
  dir=$(scene_dir drop)
  repo="$dir/repo"
  make_many_files "$repo"
  cat > "$dir/script.txt" <<EOF
open $repo HEAD^..HEAD
sleep 1000
nowait menu Go to Anything…
sleep 150
nowait key esc
dump $dir/leaving.json
open $repo HEAD
mark left
sleep 5000
mark later
quit
EOF
  run_app "$dir"
  local indexing ok left later
  indexing=$(value "$dir/leaving.json" indexing)
  ok=1
  [[ $indexing == */* ]] && ok=0
  check drop "files indexed when the review was left" "$ok" "\"$indexing\"" "some of them"
  left=$(cpu_at "$dir" left)
  later=$(cpu_at "$dir" later)
  ok=1
  ((later - left < 500)) && ok=0
  check drop "CPU ms in the 5 s after leaving" "$ok" "$((later - left))" "under 500"
}

#######################################
# Leaves a review of a linked worktree whose every git takes 3 s while it still loads: its
# gits must stop with it.
#######################################
scene_slowdrop() {
  local dir repo slow
  dir=$(scene_dir slowdrop)
  repo="$dir/repo"
  slow="$dir/slow"
  g init -q -b main "$repo"
  printf 'a\n' > "$repo/a.txt"
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  g -C "$repo" worktree add -q "$slow" -b slow
  printf 'a\nb\n' > "$slow/a.txt"
  slow=$(cd "$slow" && pwd -P)
  cat > "$dir/script.txt" <<EOF
open $repo
wait
nowait open $slow
sleep 4500
sh pgrep -lP \$PPID > $dir/during.txt
nowait open $repo HEAD
sleep 700
sh pgrep -lP \$PPID > $dir/after.txt
wait
log END
quit
EOF
  run_app "$dir" 120 "" "$slow" 3
  local during ok=1
  during=$(children_in "$dir/during.txt")
  ((during > 0)) && ok=0
  check slowdrop "gits running while the slow review loads" "$ok" "$during" "some"
  expect slowdrop "gits running after leaving it" "$(children_in "$dir/after.txt")" 0
  expect slowdrop "scene finished" "$(grep -cx END "$dir/run.log")" 1
}

#######################################
# Closes a pane while the large file it opened is still analyzed: its reader must go then, and
# the analysis must stop, rather than run on to its end for nobody.
#######################################
scene_paneclose() {
  local dir repo
  dir=$(scene_dir paneclose)
  repo="$dir/repo"
  g init -q -b main "$repo"
  printf 'a\n' > "$repo/a.txt"
  awk 'BEGIN { for (i = 0; i < 45000; i++) printf "func f%d() -> Int { return %d + 1 }\n", i, i }' > "$repo/big.swift"
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  printf 'a\nb\n' > "$repo/a.txt"
  printf 'func added() {}\n' >> "$repo/big.swift"
  cat > "$dir/script.txt" <<EOF
open $repo
wait
menu Go to Anything…
type big.swift
nowait key cmd+return
sleep 400
dump $dir/opened.json
nowait menu Close Pane
sleep 300
dump $dir/closed.json
mark closed
sleep 3000
mark later
log END
quit
EOF
  run_app "$dir"
  local closed later ok=1
  closed=$(cpu_at "$dir" closed)
  later=$(cpu_at "$dir" later)
  ((later - closed < 200)) && ok=0
  check paneclose "CPU ms after closing, once the analysis stops" "$ok" "$((later - closed))" "under 200"
  expect paneclose "the file still analyzed as its pane closed (the scene's premise)" "$(value "$dir/opened.json" settled)" false
  expect paneclose "readers with the large file open beside" "$(value "$dir/opened.json" readers)" 2
  expect paneclose "readers just after closing its pane" "$(value "$dir/closed.json" readers)" 1
  expect paneclose "scene finished" "$(grep -cx END "$dir/run.log")" 1
}

#######################################
# Checks that a value starts as it should.
# Arguments:
#   Scene name, what was checked, the value seen, and the start expected.
#######################################
expect_start() {
  local ok=1
  [[ $3 == "$4"* ]] && ok=0
  check "$1" "$2" "$ok" "$3" "$4…"
}

#######################################
# Opens files too large or too wide to take in whole, one by one and in All Changes: a file too
# large for git to compare, a change in a file with more lines than are shown whole, a file too
# large to colour, and a minified line. Each must say above what it shows why it shows only part
# of the file, or shows it plain, and a cut line must say how much of it is left out.
#######################################
scene_large() {
  local dir repo
  dir=$(scene_dir large)
  repo="$dir/repo"
  g init -q -b main "$repo"
  printf 'small\n' > "$repo/zero.txt"
  awk 'BEGIN { for (i = 0; i < 600000; i++) printf "int v%d = %d;\n", i, i }' > "$repo/lines.c"
  awk 'BEGIN { for (i = 0; i < 120000; i++) printf "let value%d = %d\n", i, i }' > "$repo/plain.swift"
  awk 'BEGIN { for (i = 0; i < 1000; i++) printf "var a%d=function(b){return b*2};", i; printf "\n" }' > "$repo/wide.js"
  g -C "$repo" add -A
  g -C "$repo" commit -qm base
  awk 'BEGIN { for (i = 0; i < 1000000; i++) print "0123456789 abcdefghij 0123456789 abcdefghij 0123456789 abcdefg" }' > "$repo/zero.txt"
  awk 'BEGIN { for (i = 0; i < 600000; i++) printf "int v%d = %d;\n", i, (i == 7 || i == 300000) ? -i : i }' > "$repo/lines.c"
  printf 'let added = 1\n' >> "$repo/plain.swift"
  awk 'BEGIN { for (i = 0; i < 1000; i++) printf "var a%d=function(b){return b*%d};", i, i == 999 ? 3 : 2; printf "\n" }' > "$repo/wide.js"
  cat > "$dir/script.txt" <<EOF
defaults readerMode file
open $repo
wait
panes $dir/lines.json
render $dir/lines.png
menu Next File
wait
panes $dir/plain.json
menu Next File
wait
panes $dir/wide.json
render $dir/wide.png
menu Next File
wait
panes $dir/huge.json
menu All Changes
wait
panes $dir/overview.json
log END
quit
EOF
  run_app "$dir"
  expect large "scene finished" "$(grep -cx END "$dir/run.log")" 1
  expect large "too large to compare" "$(value "$dir/huge.json" panes.0.rows.0)" \
    "limit Too large to compare: the file is 60.1 MB, more than the 50 MB shown whole. These are its first 10,000 lines. Open in Editor to read it all."
  expect large "its first line" "$(value "$dir/huge.json" panes.0.rows.1)" " 1 0123456789 abcdefghij 0123456789 abcdefghij 0123456789 abcdefg"
  expect large "its lines numbered" "$(value "$dir/huge.json" panes.0.rows.599)" " 599 0123456789 abcdefghij 0123456789 abcdefghij 0123456789 abcdefg"
  expect large "too many lines to show whole" "$(value "$dir/lines.json" panes.0.rows.0)" \
    "limit Only the changes show: the file has 600,000 lines, more than the 500,000 shown whole. Open in Editor to read it all."
  expect large "rows of only the changes" "$(plutil -extract panes.0.rows raw -o - "$dir/lines.json")" 19
  expect_start large "too large to colour" "$(value "$dir/plain.json" panes.0.rows.0)" "notice Plain text, without colours or definitions: the text is 2.6 MB, more than the 2 MB analyzed."
  expect large "a line too long to colour" "$(value "$dir/wide.json" panes.0.rows.0)" \
    "notice Plain text, without colours or definitions: a line is longer than 20,000 characters. Longer lines show their first 20,000 characters."
  expect_start large "a cut line says what's left out" "$(value "$dir/wide.json" panes.0.rows.1 | sed 's/^.* ⏎ /⏎ /')" "⏎ … 1"
  expect large "notices in All Changes" "$(pane_rows "$dir" overview 0 | tr , "\n" | grep -cE "^\"(limit|notice) ")" 4
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
