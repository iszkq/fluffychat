// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/utils/session_diagnostics.dart';
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:test/test.dart';

class _Database implements DatabaseApi {
  int clears = 0;
  @override
  Future<void> clear() async {
    clears++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'diagnostics observe clearing without making authenticated requests',
    () async {
      final db = _Database();
      var requests = 0;
      final phone = Client(
        'diagnostic-fixture',
        database: db,
        httpClient: MockClient((_) async {
          requests++;
          throw StateError(
            'Diagnostics must not request or revoke credentials',
          );
        }),
      );
      phone.accessToken = 'synthetic-private-token';
      final entries = <String>[];
      SessionDiagnostics.attach(
        phone,
        persist: (entry) async {
          entries.add(entry);
        },
      );
      SessionDiagnostics.qrStarted(phone);
      expect(phone.isLogged(), isTrue);
      expect(db.clears, 0);
      await phone.clear(reason: SessionClearReason.unknownToken);
      await Future<void>.delayed(Duration.zero);
      expect(db.clears, 1);
      expect(requests, 0);
      expect(entries.single, contains('unknownToken'));
      expect(entries.single, contains('seconds since QR:'));
      expect(entries.single, isNot(contains('synthetic-private-token')));
      expect(
        Logs().outputEvents.map((e) => e.toFormattedString()).join('\n'),
        contains('unknownToken'),
      );
    },
  );
}
