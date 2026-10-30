#!/bin/bash
# Writes the app's version file, in KOReader's v<year>.<month>-<count>-g<hash>
# format. `git describe` can't produce it here because this fork has no tags,
# and a blank version breaks whatever compares versions: QuickStart, for one,
# would show the guide on every launch.
#
#   write-git-rev.sh <repo-root> <app-payload-dir>
set -euo pipefail

month="$(git -C "$1" log -1 --format=%cd --date=format:%Y.%m)"
count="$(git -C "$1" rev-list --count HEAD)"
hash="$(git -C "$1" rev-parse --short=8 HEAD)"
echo "v${month}-${count}-g${hash}" >"$2/git-rev"
