#!/bin/zsh
# Photographs every screen the app can be launched straight into, one
# launch per scene, into ios/build/screenshots/. No taps: each scene is a
# set of CWG_* launch variables the app already understands, so a run is
# a visual diff of the whole surface after any change.
#
#   scripts/screenshots.sh              # build, then shoot everything
#   scripts/screenshots.sh --no-build   # reuse the last build
#   scripts/screenshots.sh onboarding   # only scenes whose name matches
#
# Uses the booted simulator (boot one first). Scenes run on the account
# that's signed in there; the first-run pages use the preview mode, so
# nothing is written. CWG_NO_PROMPTS keeps system alerts out of frame.

set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE=com.cansaglam.CanWeGo
# Derived data lives outside the repo: files under ~/Desktop pick up
# Finder metadata that codesign refuses ("resource fork ... not allowed").
DD=${TMPDIR:-/tmp}/cwg-screenshots-dd
OUT=build/screenshots
FILTER=""
BUILD=1
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    *) FILTER="$arg" ;;
  esac
done

if (( BUILD )); then
  xcodebuild -project CanWeGo.xcodeproj -scheme CanWeGo \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -configuration Debug -derivedDataPath "$DD" build 2>&1 \
    | rg -n "error:|BUILD (SUCCEEDED|FAILED)" || true
fi
xcrun simctl install booted "$DD/Build/Products/Debug-iphonesimulator/CanWeGo.app"
mkdir -p "$OUT"

# shoot NAME DELAY VAR=1 VAR=value ...
shoot() {
  local name=$1 delay=$2; shift 2
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && return 0
  xcrun simctl terminate booted "$BUNDLE" 2>/dev/null || true
  local env_args=(SIMCTL_CHILD_CWG_NO_PROMPTS=1)
  for kv in "$@"; do env_args+=("SIMCTL_CHILD_$kv"); done
  env "${env_args[@]}" xcrun simctl launch booted "$BUNDLE" >/dev/null
  sleep "$delay"
  xcrun simctl io booted screenshot "$OUT/$name.png" >/dev/null 2>&1
  echo "  $OUT/$name.png"
}

echo "Library"
shoot library-events 5
shoot library-places 5 CWG_TAB=1
shoot library-map 6 CWG_MAP=1
shoot library-search 4 CWG_SEARCH=1
shoot library-chip 4 CWG_CHIP=gig
shoot library-stale 4 CWG_STALE=1
shoot library-share-tip 4 CWG_TIPS=1
shoot item-detail 5 CWG_OPEN=festival

echo "Capture"
shoot capture-composer 4 CWG_CAPTURE=1
shoot capture-composer-ticker 7 CWG_CAPTURE=1
shoot capture-duplicate 6 CWG_CAPTURE=1 CWG_DUPE=1
shoot capture-blank 4 CWG_CAPTURE=1 CWG_BLANK=1

echo "Settings and gates"
shoot settings 4 CWG_SETTINGS=1
shoot settings-account 5 CWG_SETTINGS=1 CWG_SCROLL=account
shoot settings-join 5 CWG_SETTINGS=1 CWG_JOIN=1
shoot update-required 4 CWG_FORCE_UPDATE=1

echo "First run (preview mode)"
for page in welcome name code home save joined notify; do
  shoot "onboarding-$page" 5 CWG_ONBOARDING_PREVIEW=1 "CWG_ONBOARDING_PAGE=$page"
done
for theme in midnight cobalt ink forest moss umber wine oat stone; do
  shoot "library-theme-$theme" 5 "CWG_THEME=$theme"
done

# Leave the app as it was found: a plain launch, no scene variables.
xcrun simctl terminate booted "$BUNDLE" 2>/dev/null || true
xcrun simctl launch booted "$BUNDLE" >/dev/null
echo "Done: $(ls "$OUT" | wc -l | tr -d ' ') screenshots in $OUT"
