#!/usr/bin/env bash
#
# Plays scenes that once crashed Sextant against a ghostty checkout, and fails when the app
# doesn't come through one.
#
# Each scene runs in the glass look, in light and in dark, behind the windows in use. The app
# opens a copy of the checkout that shares its objects, so its review state stays out of the
# checkout.
#
# Usage: Tests/scenes.sh <ghostty checkout> [app] (inside `nix develop`)
#   app: a Sextant.app to play the scenes with, such as a release, instead of building one.

set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
ghostty=$(cd "$1" && pwd)
work="$here/.build/scenes"
repo="$work/ghostty"
app=${2:-$work/Sextant.app}
bundle_id=com.shrikanthup.Sextant.scenes

#######################################
# Builds the release app with its own bundle ID, so it keeps its own settings.
#######################################
build_app() {
  swift build -c release --product SextantApp >/dev/null
  swift build -c release --product sextant >/dev/null
  bash "$here/bundle.sh" "$(swift build -c release --show-bin-path)" "$work" "$(command -v git)" "$SEXTANT_SYNTAX" >/dev/null
  plutil -replace CFBundleIdentifier -string "$bundle_id" "$app/Contents/Info.plist"
  plutil -remove CFBundleURLTypes "$app/Contents/Info.plist"
  codesign --force --sign - "$app" 2>/dev/null
}

#######################################
# Makes a repository that borrows the checkout's objects, at the commit the scenes review.
# Arguments:
#   Commit to check out.
#######################################
make_repo() {
  rm -rf "$repo"
  git init -q "$repo"
  echo "$ghostty/.git/objects" > "$repo/.git/objects/info/alternates"
  git -C "$repo" -c advice.detachedHead=false checkout -q "$1"
}

#######################################
# Plays a scene in the glass look, in light and in dark.
# Arguments:
#   Name to report.
#   Scene, as automation commands, with APPEARANCE for the appearance.
# Returns:
#   1 if the app didn't reach the end of the scene in either appearance.
#######################################
play() {
  local name=$1 scene=$2 failed=0 appearance log
  for appearance in light dark; do
    log="$work/$appearance.log"
    rm -f "$log"
    defaults delete "$bundle_id" >/dev/null 2>&1 || true
    printf 'defaults look glass\n%s\nlog END\nquit\n' "${scene//APPEARANCE/$appearance}" > "$work/scene.txt"
    (sleep 120 && pkill -f "$app/Contents/MacOS/Sextant") &
    local watchdog=$!
    open -n -g -W -a "$app" --stderr "$work/$appearance.stderr" --args --automation "$work/scene.txt" --log "$log" --background
    kill "$watchdog" 2>/dev/null || true
    if grep -qx END "$log" 2>/dev/null; then
      printf '%-44s %-5s ok\n' "$name" "$appearance"
    else
      printf '%-44s %-5s FAILED, see %s\n' "$name" "$appearance" "$work/$appearance.stderr"
      failed=1
    fi
  done
  defaults delete "$bundle_id" >/dev/null 2>&1 || true
  return "$failed"
}

mkdir -p "$work"
[[ -n ${2:-} ]] || build_app
bundle_id=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")
failed=0

make_repo a573781c6
play "Opening page.zig through Go to Anything" "open $repo a573781c6^..a573781c6
resize 1500 950
appearance APPEARANCE
wait
sleep 1500
menu Go to Anything…
type terminal/page.zig
sleep 800
key return
wait
sleep 1500" || failed=1

exit "$failed"
