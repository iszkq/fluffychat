#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail

cd "$(dirname "$0")/.."

# Flutter's browser test server serves test/ but does not mount the generated
# asset bundle at /assets. The Opus plugin loads real JS/WASM through that URL.
# Flutter creates the bundle before the browser starts, so this link can point
# at a directory that does not exist yet on a clean checkout.
if [[ -e test/assets || -L test/assets ]]; then
  echo 'test/assets already exists; refusing to replace it.' >&2
  exit 1
fi
ln -s ../build/unit_test_assets test/assets
trap 'rm -- test/assets' EXIT

flutter test --no-pub --platform chrome --timeout 2m \
  test/voice_message_ogg_encoder_web_test.dart
