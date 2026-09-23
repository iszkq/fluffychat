#!/bin/sh -ve

# SPDX-FileCopyrightText: 2019-Present Christian Kußowski
# SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
#
# SPDX-License-Identifier: AGPL-3.0-or-later

if [ -z "${NTFY_TOPIC:-}" ]; then
  echo "NTFY_TOPIC is required for the iOS ntfy push build."
  exit 1
fi

PUSH_NOTIFICATIONS_GATEWAY_URL="${PUSH_NOTIFICATIONS_GATEWAY_URL:-https://push.fluffychat.im/_matrix/push/v1/notify}"

flutter clean
flutter pub get

# Reload all cocoapods
(
  cd ios
  rm -rf Pods Podfile.lock
  pod install
  pod update
)

# pub get hardcodes FlutterGeneratedPluginSwiftPackage to iOS 13.0; regenerate so
# it picks up the project's IPHONEOS_DEPLOYMENT_TARGET before xcodebuild.
flutter build ios --config-only --release \
  --dart-define=NTFY_TOPIC="$NTFY_TOPIC" \
  --dart-define=PUSH_NOTIFICATIONS_GATEWAY_URL="$PUSH_NOTIFICATIONS_GATEWAY_URL"

# Build and open archive dialog
xcodebuild \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -archivePath build/Runner.xcarchive \
  archive && open -a Xcode build/Runner.xcarchive
