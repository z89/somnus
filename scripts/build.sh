#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
derived_data="$repo_dir/.build/release"
app_product="$derived_data/Build/Products/Release/Somnus.app"
lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
signing=unsigned

# xcodebuild registers a macOS app from DerivedData with Launch Services. That
# leaves Control Center choosing between the build copy and /Applications, both
# of which contain the same widget identifier. Keep the build artifact, but
# unregister it whenever this script exits so the installed app is authoritative.
unregister_build_copy() {
  if [ -d "$app_product" ] && [ -x "$lsregister" ]; then
    "$lsregister" -u "$app_product" >/dev/null 2>&1 || true
  fi
}
trap unregister_build_copy EXIT

case "${1:-}" in
  "") ;;
  --signed) signing=signed ;;
  *) echo "usage: $0 [--signed]" >&2; exit 64 ;;
esac

cd "$repo_dir"

if [ "$signing" = signed ]; then
  if [ ! -f Config/Local.xcconfig ]; then
    echo "Config/Local.xcconfig is required for a signed build." >&2
    echo "Copy Config/Local.xcconfig.example and set DEVELOPMENT_TEAM." >&2
    exit 1
  fi
  xcodebuild -project somnus.xcodeproj -scheme Somnus \
    -configuration Release -derivedDataPath "$derived_data" build
else
  xcodebuild -project somnus.xcodeproj -scheme Somnus \
    -configuration Release -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO build
fi

echo "Built $app_product ($signing)."
