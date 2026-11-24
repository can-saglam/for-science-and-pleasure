#!/bin/zsh
# A TestFlight build, start to finish: the next build number in every
# target, a "Build N" commit tagged build-N, pushed, then the archive opened
# in Xcode's Organizer for Distribute App → App Store Connect.
#
#   scripts/release.sh            # next build number
#   scripts/release.sh 160        # a given one (must be higher)
#   scripts/release.sh --no-push  # commit and tag, but don't push
#
# Only from a clean main that matches origin, so every build on TestFlight
# is a commit anyone can check out.

set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT=CanWeGo.xcodeproj/project.pbxproj
push=1
wanted=""
for arg in "$@"; do
  case $arg in
    --no-push) push=0 ;;
    <->) wanted=$arg ;;
    *) echo "usage: scripts/release.sh [build] [--no-push]" >&2; exit 64 ;;
  esac
done

[[ $(git branch --show-current) == main ]] || { echo "Not on main." >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Uncommitted changes; commit or stash them first." >&2; exit 1; }
git fetch -q origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "main and origin/main differ; pull or push first." >&2; exit 1; }

current=$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*;' $PROJECT | grep -o '[0-9]*')
count=$(grep -c "CURRENT_PROJECT_VERSION = $current;" $PROJECT)
total=$(grep -c 'CURRENT_PROJECT_VERSION = ' $PROJECT)
(( count == total )) || { echo "Targets disagree on the build number; fix $PROJECT first." >&2; exit 1; }
next=${wanted:-$((current + 1))}
(( next > current )) || { echo "Build $next isn't above the current $current." >&2; exit 1; }
version=$(grep -m1 -o 'MARKETING_VERSION = [^;]*;' $PROJECT | sed 's/MARKETING_VERSION = //; s/;//')

echo "Version $version, build $current → $next"
sed -i '' "s/CURRENT_PROJECT_VERSION = $current;/CURRENT_PROJECT_VERSION = $next;/g" $PROJECT
git add $PROJECT
git commit -q -m "Build $next"
git tag "build-$next"
if (( push )); then
  git push -q origin main "build-$next"
  echo "Pushed main and build-$next"
fi

archive="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)/CanWeGo b$next.xcarchive"
echo "Archiving to $archive"
# xcodebuild ends some steps with "failed with exit code 0": noise, not failure.
xcodebuild archive -project CanWeGo.xcodeproj -scheme CanWeGo -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" -allowProvisioningUpdates -quiet
built=$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:CFBundleVersion" "$archive/Info.plist")
[[ $built == "$next" ]] || { echo "The archive says build $built, not $next." >&2; exit 1; }
open "$archive"
echo "Build $next is in the Organizer: Distribute App → App Store Connect."
