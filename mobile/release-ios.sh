#!/usr/bin/env bash
# Builds the iOS app and uploads it to App Store Connect for TestFlight (#34).
#
#   mobile/release-ios.sh
#
# Needs: Xcode signed in to the publishing team (Xcode > Settings > Accounts), the app record in
# App Store Connect (bundle xyz.chromedao.smartssi). Build numbers are incremented by App Store Connect.
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-RU6ZU6HVZT}"
OUT=$(mktemp -d)

./build-ios.sh
sed "s/\$(DEVELOPMENT_TEAM)/$DEVELOPMENT_TEAM/" ios/ExportOptions.plist > "$OUT/ExportOptions.plist"
xcodebuild -project ios/SmartSSI.xcodeproj -scheme SmartSSI -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/SmartSSI.xcarchive" -allowProvisioningUpdates archive -quiet
xcodebuild -exportArchive -archivePath "$OUT/SmartSSI.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" -allowProvisioningUpdates
echo "Uploaded. Processing takes 5-30 min, then the build shows in App Store Connect > TestFlight."
