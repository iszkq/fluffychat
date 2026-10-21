// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

/// SQLCipher reports wrong keys as "not a database". Do not reset those files.
bool isRecoverableDatabaseCorruption(Object error) =>
    error.toString().toLowerCase().contains('database disk image is malformed');

/// Copy all files before removing any, preserving the WAL for manual recovery.
Future<String> preserveCorruptDatabase(String path) async {
  final backup = '$path.corrupt-${DateTime.now().microsecondsSinceEpoch}';
  final files = <File>[];
  for (final suffix in ['', '-wal', '-shm', '-journal']) {
    final file = File('$path$suffix');
    if (await file.exists()) {
      await file.copy('$backup$suffix');
      files.add(file);
    }
  }
  for (final file in files) {
    await file.delete();
  }
  return backup;
}
