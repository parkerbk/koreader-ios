#!/bin/bash
# Merges the latest KOReader into this fork on a new branch, base/ included,
# then rebuilds the native libraries. Nothing is pushed: test the branch, then
# merge it into master.
#
#   platform/ios/update-koreader.sh
#
# Stops at any merge conflict: fix it, commit, and run the script again.
#
# Afterwards, check on the simulator (platform/ios/run-simulator.sh) that the
# menu, dialogs, rotation and a book still work. Merges can't catch KOReader
# renaming something that frontend/ui/nativedialogs.lua or nativetouchmenu.lua
# rely on.
set -euo pipefail
cd "$(dirname "$0")/../.."

KOREADER=https://github.com/koreader/koreader.git
KOREADER_BASE=https://github.com/koreader/koreader-base.git
BRANCH="koreader-update-$(date +%Y%m%d)"

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "Commit or stash your changes first." >&2
    exit 1
fi

git fetch -q "${KOREADER}" master
UPSTREAM="$(git rev-parse FETCH_HEAD)"
UPSTREAM_BASE="$(git ls-tree "${UPSTREAM}" base | awk '{print $3}')"

if [ "$(git branch --show-current)" != "${BRANCH}" ]; then
    git checkout -q -b "${BRANCH}"
fi

echo "==> Merging base/"
git -C base fetch -q "${KOREADER_BASE}" master
git -C base checkout -q -B "${BRANCH}"
git -C base merge --no-edit "${UPSTREAM_BASE}"
git -C base submodule update --init --recursive

echo "==> Merging KOReader"
# base/ always conflicts as a submodule, so it's settled to the merge above.
git merge --no-commit --no-edit "${UPSTREAM}" || true
git add base
if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
    echo "Fix these conflicts, commit, then run this again:" >&2
    git diff --name-only --diff-filter=U >&2
    exit 1
fi
git diff --cached --quiet || git commit -q -m "Merge KOReader into the iOS fork"
git submodule update --init l10n resources/fonts

echo "==> Rebuilding"
rm -f platform/ios/Info.plist
make TARGET=ios xcodeproj

echo "==> Done on ${BRANCH}. Test it, push base/, then merge into master."
