#!/bin/sh -ve

# SPDX-FileCopyrightText: 2019-Present Christian Kußowski
# SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
#
# SPDX-License-Identifier: AGPL-3.0-or-later

PUSH_NOTIFICATIONS_GATEWAY_URL="${PUSH_NOTIFICATIONS_GATEWAY_URL:-https://flchat.221819.best/_matrix/push/v1/notify}"

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
  --dart-define=PUSH_NOTIFICATIONS_GATEWAY_URL="$PUSH_NOTIFICATIONS_GATEWAY_URL"

# Build and open archive dialog
xcodebuild \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -archivePath build/Runner.xcarchive \
  archive && open -a Xcode build/Runner.xcarchive
