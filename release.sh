#!/usr/bin/env bash
#
# Builds the release zip of Sextant.app that the Homebrew cask installs.
#
# Usage: release.sh <out-dir>
#
# Builds .#release with nix, compiles icon/Sextant.icon into the bundle's asset catalog, seals
# the bundle with an ad-hoc signature, and zips it as <out-dir>/Sextant-<version>.zip. Prints the
# version, the zip's path and its SHA-256, one per line. Publishing is left to the caller.
#
# Compiling the icon needs Xcode's actool, which the CI runner has; nix builds outside this
# script ship only the flat icon/AppIcon.icns.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
out=$1
version=$(< "$here/VERSION")
store=$(nix build --no-link --print-out-paths "$here#release")

mkdir -p "$out"
app="$out/Sextant.app"
rm -rf "$app"
cp -R "$store/Applications/Sextant.app" "$app"
chmod -R u+w "$app"
xcrun actool "$here/icon/Sextant.icon" --compile "$app/Contents/Resources" --app-icon Sextant \
  --output-partial-info-plist "$out/icon-info.plist" --include-all-app-icons \
  --target-device mac --minimum-deployment-target 26.0 --platform macosx >/dev/null
plutil -replace CFBundleIconName -string Sextant "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app/Contents/Helpers/sextant"
/usr/bin/codesign --force --sign - "$app"

zip="$out/Sextant-$version.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

echo "$version"
echo "$zip"
shasum -a 256 "$zip" | cut -d' ' -f1
