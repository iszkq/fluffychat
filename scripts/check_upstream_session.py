#!/usr/bin/env python3
"""Verify the pinned upstream authentication/session baseline without networking."""
import hashlib
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
baseline = json.loads((root / 'docs/audits/upstream-session-baseline.json').read_text())
for name, expected in baseline['files'].items():
    actual = hashlib.sha256((root / name).read_bytes().replace(b'\r\n', b'\n')).hexdigest()
    assert actual == expected, f'Upstream session source changed: {name}'
manager = (root / 'lib/utils/client_manager.dart').read_text()
assert re.search(r'onSoftLogout:\s*enableSoftLogout\s*\?\s*\(c\)\s*=>\s*c\.refreshAccessToken\(\)\s*:\s*null', manager)
assert 'httpClient: CustomHttpClient.createHTTPClient(),' in manager
assert 'session_refresh' not in manager
assert f"matrix: {baseline['matrixSdk']}" in (root / 'pubspec.yaml').read_text()
assert not (root / 'pubspec_overrides.yaml').exists(), 'Unexpected SDK override'
for name in ['session_refresh.dart', 'session_refresh_transport.dart', 'session_backup.dart']:
    assert not (root / 'lib/utils' / name).exists(), f'Custom session layer returned: {name}'
print(f"Upstream session baseline verified: {baseline['commit']} / matrix {baseline['matrixSdk']}")
