#!/usr/bin/env bash
#
# Builds the release zip of Revue.app that the Homebrew cask installs.
#
# Usage: release.sh <out-dir>
#
# Builds .#release with nix, seals the bundle with an ad-hoc signature, and zips it as
# <out-dir>/Revue-<version>.zip. Prints the version, the zip's path and its SHA-256, one per
# line. Publishing is left to the caller.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
out=$1
version=$(< "$here/VERSION")
store=$(nix build --no-link --print-out-paths "$here#release")

mkdir -p "$out"
app="$out/Revue.app"
rm -rf "$app"
cp -R "$store/Applications/Revue.app" "$app"
chmod -R u+w "$app"
/usr/bin/codesign --force --sign - "$app/Contents/Helpers/revue"
/usr/bin/codesign --force --sign - "$app"

zip="$out/Revue-$version.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

echo "$version"
echo "$zip"
shasum -a 256 "$zip" | cut -d' ' -f1
