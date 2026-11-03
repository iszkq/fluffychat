#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Run unchanged QR protocol + dialog sources without unrelated native hooks.

The full app pulls in webcrypto/SQLCipher native builds even for these tests.
This harness copies the exact production sources into a minimal Flutter package;
it does not stub cryptography, UI components, localization, or the login flow.
Matrix SDK adapter / scanner wiring are checked separately by flutter analyze.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--flutter', default=shutil.which('flutter'))
parser.add_argument('--js-project', help='Project containing matrix-js-sdk and qrcode')
args = parser.parse_args()
if not args.flutter:
    parser.error('Pass --flutter or add Flutter to PATH')
root = Path(__file__).resolve().parents[1]
subprocess.run([args.flutter, 'gen-l10n'], cwd=root, check=True)
target = root / '.dart_tool' / 'qr_login_validation'
target.mkdir(parents=True, exist_ok=True)
files = [
    'lib/utils/qr_login/qr_login_payload.dart',
    'lib/utils/qr_login/msc4108_channel.dart',
    'lib/utils/qr_login/qr_login_existing_device.dart',
    'lib/utils/qr_login/matrix_qr_login_account.dart',
    'lib/utils/qr_login/credential_vault.dart',
    'lib/utils/qr_login/matrix_credential_vault.dart',
    'lib/pages/new_private_chat/qr_login_dialog.dart',
    'lib/widgets/adaptive_dialogs/adaptive_dialog_action.dart',
    'lib/config/app_config.dart',
    'lib/utils/sign_in_flows/sign_in_method.dart',
    'lib/utils/sign_in_flows/login_discovery.dart',
    'lib/utils/crypto_identity_watcher.dart',
    'test/login_discovery_test.dart',
    'test/crypto_identity_watcher_test.dart',
    'test/qr_login_test.dart',
    'test/sign_in_method_test.dart',
    'test/qr_login_account_test.dart',
    'test/cached_secrets_test.dart',
    'test/credential_vault_test.dart',
    'test/matrix_credential_vault_test.dart',
    'test/qr_login_dialog_test.dart',
    'scripts/qr_login_test_peer.mjs',
]
files += [str(path.relative_to(root)).replace('\\', '/') for path in (root / 'scripts/qr_login_pc_peer').rglob('*') if path.is_file() and 'node_modules' not in path.parts]
files += [str(path.relative_to(root)).replace('\\', '/') for path in (root / 'lib/l10n').glob('*.dart')]
manifest = {}
for name in files:
    source, destination = root / name, target / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    assert hashlib.sha256(destination.read_bytes()).hexdigest() == digest
    manifest[name] = digest
(target / 'source-sha256.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
(target / 'pubspec.yaml').write_text('''name: fluffychat
environment:
  sdk: '>=3.13.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  flutter_localizations:
    sdk: flutter
  cupertino_ui: 1.1.4
  material_ui: 1.7.0
  intl: 0.20.3
  cryptography: 2.9.0
  http: 1.6.0
  matrix: 14.1.0
  flutter_secure_storage: 11.2.0
  url_launcher: 6.3.3
dev_dependencies:
  flutter_test:
    sdk: flutter
  test: 1.31.1
flutter:
  uses-material-design: true
''', encoding='utf-8')
env = os.environ.copy()
if args.js_project:
    env['QR_LOGIN_JS_PROJECT'] = str(Path(args.js_project).resolve())
for command in [['pub', 'get'], ['test', '--no-pub', '--concurrency=1', '--reporter', 'expanded', 'test/qr_login_test.dart', 'test/qr_login_dialog_test.dart', 'test/qr_login_account_test.dart', 'test/cached_secrets_test.dart', 'test/credential_vault_test.dart', 'test/matrix_credential_vault_test.dart', 'test/sign_in_method_test.dart', 'test/login_discovery_test.dart', 'test/crypto_identity_watcher_test.dart']]:
    subprocess.run([args.flutter, *command], cwd=target, env=env, check=True)
print(f'QR login validation passed. Source hashes: {target / "source-sha256.json"}')
