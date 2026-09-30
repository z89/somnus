#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
derived_data="$repo_dir/.build/release-check"
analysis_app="$derived_data/Build/Products/Debug/Somnus.app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# The analyzed app is not an install candidate. Do not leave its widget
# extension competing with /Applications/Somnus.app in Control Center.
unregister_analysis_copy() {
  if [ -d "$analysis_app" ] && [ -x "$lsregister" ]; then
    "$lsregister" -u "$analysis_app" >/dev/null 2>&1 || true
  fi
}
trap unregister_analysis_copy EXIT

cd "$repo_dir"

# Whitespace errors anywhere in the tree, not just in uncommitted changes.
git diff --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD
git diff --check
git diff --cached --check
plutil -lint Resources/*.plist Resources/*.entitlements >/dev/null
./scripts/check-docs.py
for script in scripts/*.sh; do sh -n "$script"; done
test -x scripts/build.sh
test -x scripts/install.sh
test -x scripts/uninstall.sh
./scripts/test.sh
./scripts/build.sh

xcodebuild -project somnus.xcodeproj -scheme Somnus \
  -configuration Debug -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO analyze

test -f "$repo_dir/.build/release/Build/Products/Release/Somnus.app/Contents/Resources/Somnus.icns"
echo "Release checks passed."
