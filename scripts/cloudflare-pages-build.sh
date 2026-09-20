#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

project_root="$(pwd)"
tools_dir="${project_root}/.cloudflare-tools"
flutter_version="$(
  sed -n \
    's/^[[:space:]]*flutter:[[:space:]]*\([^[:space:]#]*\).*/\1/p' \
    .tool_versions.yaml
)"

if [ -z "${flutter_version}" ]; then
  echo 'Unable to read the Flutter version from .tool_versions.yaml' >&2
  exit 1
fi

mkdir -p "${tools_dir}/bin"

export CARGO_HOME="${tools_dir}/cargo"
export RUSTUP_HOME="${tools_dir}/rustup"
export PATH="${tools_dir}/bin:${tools_dir}/flutter/bin:${CARGO_HOME}/bin:${PATH}"

if [ ! -x "${tools_dir}/flutter/bin/flutter" ]; then
  git clone \
    --depth 1 \
    --branch "${flutter_version}" \
    https://github.com/flutter/flutter.git \
    "${tools_dir}/flutter"
fi

if [ ! -x "${CARGO_HOME}/bin/rustup" ]; then
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | \
    sh -s -- -y --no-modify-path --profile minimal --default-toolchain stable
fi

rustup toolchain install nightly-x86_64-unknown-linux-gnu \
  --profile minimal \
  --component rust-src

if ! command -v yq >/dev/null 2>&1; then
  machine_arch="$(uname -m)"
  case "${machine_arch}" in
    x86_64) yq_arch="amd64" ;;
    aarch64|arm64) yq_arch="arm64" ;;
    *)
      echo "Unsupported build architecture: ${machine_arch}" >&2
      exit 1
      ;;
  esac
  curl -fsSL \
    "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}" \
    -o "${tools_dir}/bin/yq"
  chmod +x "${tools_dir}/bin/yq"
fi

flutter config --enable-web --no-analytics
flutter precache --web

./scripts/prepare-web.sh
flutter build web \
  --release \
  --dart-define=FLUTTER_WEB_CANVASKIT_URL=canvaskit/

cp config.sample.json build/web/config.json

# Cloudflare custom domains can apply a browser TTL to main.dart.js even when
# Pages itself has a newer deployment. Give every deployment a unique entry
# point URL so an ordinary refresh immediately loads the new application.
build_revision="$(git rev-parse --short=12 HEAD 2>/dev/null || date +%s)"
for bootstrap_file in build/web/index.html build/web/flutter_bootstrap.js; do
  if [ -f "${bootstrap_file}" ]; then
    sed -i "s#main\.dart\.js#main.dart.js?v=${build_revision}#g" "${bootstrap_file}"
  fi
done
