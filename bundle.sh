#!/usr/bin/env bash
#
# Assembles Revue.app from SwiftPM build products.
#
# Usage: bundle.sh <bin-dir> <out-dir> <git-path> <syntax-dir> [codesign-command]
#
# <git-path> is the git the app runs. Pass "" to leave it out, so the app finds git on the
# user's PATH; a build that ships outside the nix store has no git of its own to point at.
# <syntax-dir> holds the tree-sitter grammars and queries (nix build .#syntaxRuntime).
# The version comes from the VERSION file beside this script.
# Without a codesign command, the binaries keep their linker ad-hoc signatures.

set -euo pipefail

bin=$1
out=$2
git=$3
syntax=$4
sign=${5:-}
here=$(cd "$(dirname "$0")" && pwd)
version=$(< "$here/VERSION")
git_key=""
if [ -n "$git" ]; then
  git_key="<key>RevueGitPath</key><string>$git</string>"
fi

app="$out/Revue.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
cp -RL "$syntax" "$app/Contents/Resources/syntax"
chmod -R u+w "$app/Contents/Resources/syntax"
cp "$bin/RevueApp" "$app/Contents/MacOS/Revue"
cp "$bin/revue" "$app/Contents/Helpers/revue"
if [ -f "$here/icon/AppIcon.icns" ]; then
  cp "$here/icon/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
fi

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.shrikanthup.Revue</string>
  <key>CFBundleName</key><string>Revue</string>
  <key>CFBundleDisplayName</key><string>Revue</string>
  <key>CFBundleExecutable</key><string>Revue</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  $git_key
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.shrikanthup.Revue</string>
      <key>CFBundleURLSchemes</key><array><string>revue</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

if [ -n "$sign" ]; then
  "$sign" --force --sign - "$app/Contents/Helpers/revue"
  "$sign" --force --sign - "$app"
fi
echo "$app"
