#!/bin/sh
# Builds a Release archive, exports it to a local .ipa and uploads that to App
# Store Connect for internal TestFlight testing.
#
#   BUILD_NUMBER=N platform/ios/testflight.sh               # archive, export, upload
#   BUILD_NUMBER=N platform/ios/testflight.sh --no-upload   # archive and export only
#
# N must be higher than the last uploaded build. Needs an app record for
# com.bparker2003.koreader, an Apple Distribution certificate in the keychain,
# and ASC_KEY_ID and ASC_ISSUER_ID set for an App Store Connect API key whose
# file is in ~/.appstoreconnect/private_keys/.
#
# Signing is local. If a build fails on a missing profile (new capability, new
# bundle ID, expired cert), fix it in Xcode by hand and rerun; don't add
# -allowProvisioningUpdates here.
set -eu
cd "$(dirname "$0")/../.."

BUILD=${BUILD_NUMBER:?set BUILD_NUMBER}
ARCHIVE="build/KOReader-$BUILD.xcarchive"

echo "==> Archiving build $BUILD"
xcodebuild archive -quiet \
  -project KOReader.xcodeproj \
  -scheme KOReader \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD"

echo "==> Exporting the .ipa"
rm -rf build/export
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist platform/ios/ExportOptions.plist \
  -exportPath build/export

if [ "${1:-}" = "--no-upload" ]; then
  echo "==> Exported to build/export (not uploaded)"
  exit 0
fi

echo "==> Uploading to App Store Connect"
xcrun altool --upload-app --type ios \
  --file "$(ls build/export/*.ipa)" \
  --apiKey "${ASC_KEY_ID:?set ASC_KEY_ID}" \
  --apiIssuer "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"

echo "==> Uploaded build $BUILD. It appears in TestFlight once processing finishes."
