#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail

# Run the real UIKit JPEG conversion in an iOS simulator, without requiring a
# camera device, app signing or a separate Xcode test target.
simulator_id=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
print(next(d["udid"] for runtime, group in devices.items() if "iOS" in runtime
           for d in group if d["name"].startswith("iPhone")))
')
xcrun simctl boot "$simulator_id" || true
xcrun simctl bootstatus "$simulator_id" -b
camera_test_dir=$(mktemp -d)
trap 'rm -rf "$camera_test_dir"; xcrun simctl shutdown "$simulator_id" || true' EXIT
xcrun --sdk iphonesimulator swiftc -parse-as-library \
  -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target "$(uname -m)-apple-ios17.0-simulator" \
  ios/Runner/CameraPhotoSupport.swift test/ios/camera_photo_support_test.swift \
  -o "$camera_test_dir/camera-tests"
xcrun simctl spawn "$simulator_id" "$camera_test_dir/camera-tests"
