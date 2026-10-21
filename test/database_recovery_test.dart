// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:fluffychat/utils/database_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only explicit corruption qualifies for automatic recovery', () {
    expect(
      isRecoverableDatabaseCorruption(
        Exception('database disk image is malformed'),
      ),
      isTrue,
    );
    for (final message in [
      'file is not a database',
      'database is locked',
      'unable to open database file',
      'Keychain access denied',
      'migration failed',
    ]) {
      expect(isRecoverableDatabaseCorruption(Exception(message)), isFalse);
    }
  });

  test(
    'preserves the database and WAL before releasing their original paths',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fluffy-db-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/account.sqlite';
      await File(path).writeAsBytes([1, 2, 3]);
      await File('$path-wal').writeAsBytes([4, 5, 6]);
      final backup = await preserveCorruptDatabase(path);
      expect(await File(backup).readAsBytes(), [1, 2, 3]);
      expect(await File('$backup-wal').readAsBytes(), [4, 5, 6]);
      expect(await File(path).exists(), isFalse);
      expect(await File('$path-wal').exists(), isFalse);
    },
  );
}
