#!/bin/sh -ve

# SPDX-FileCopyrightText: 2019-Present Christian Kußowski
# SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
#
# SPDX-License-Identifier: AGPL-3.0-or-later

flutter clean
flutter config --enable-swift-package-manager
flutter pub get

# Regenerate plugin configuration before archiving so Swift Package targets pick
# up the project's deployment target.
flutter build ios --config-only --release

# Build and open archive dialog
xcodebuild \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -archivePath build/Runner.xcarchive \
  archive && open -a Xcode build/Runner.xcarchive
