// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:fluffychat/utils/session_diagnostics.dart';
import 'package:fluffychat/utils/session_refresh.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:test/test.dart';

class _MemoryDatabase implements DatabaseApi {
  Map<String, dynamic>? row = {'refresh_token': 'phone-refresh'};
  int clears = 0;

  @override
  Future<Map<String, dynamic>?> getClient(String name) async => row;

  @override
  Future<void> storeClient({
    required String homeserverUrl,
    required String token,
    DateTime? tokenExpiresAt,
    String? refreshToken,
    required String userId,
    String? deviceId,
    String? deviceName,
    String? prevBatch,
    String? olmAccount,
    String? oidcClientId,
  }) async {
    row = {
      'token': token,
      'refresh_token': refreshToken,
      'device_id': deviceId,
    };
  }

  @override
  Future<void> clear() async {
    clears++;
    row = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Phone extends Client {
  _Phone(_MemoryDatabase db, http.Client transport, {bool guarded = true})
    : super(
        'session-refresh-test',
        database: db,
        httpClient: transport,
        onSoftLogout: guarded ? refreshSessionSafely : null,
      ) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'phone-access';
  }

  @override
  String get userID => '@alice:matrix.example';
  @override
  String get deviceID => 'PHONE';
  @override
  DateTime get accessTokenExpiresAt => DateTime.fromMillisecondsSinceEpoch(0);
}

http.Response rejected(int status, String code) => http.Response(
  jsonEncode({'errcode': code, 'error': 'Synthetic failure'}),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  test(
    'unprotected SDK clears a valid phone session on refresh HTTP 503',
    () async {
      final db = _MemoryDatabase();
      final phone = _Phone(
        db,
        MockClient((_) async => rejected(503, 'M_UNKNOWN')),
        guarded: false,
      );
      await expectLater(
        phone.ensureNotSoftLoggedOut(),
        throwsA(isA<MatrixException>()),
      );
      expect(db.clears, 1);
      expect(phone.isLogged(), isFalse);
    },
  );

  test(
    'after QR, transient refresh failures preserve phone data and the next refresh succeeds',
    () async {
      final db = _MemoryDatabase();
      var requests = 0;
      final phone = _Phone(
        db,
        MockClient((request) async {
          expect(request.url.path, '/_matrix/client/v3/refresh');
          expect(jsonDecode(request.body)['refresh_token'], 'phone-refresh');
          requests++;
          if (requests == 1) return rejected(503, 'M_UNKNOWN');
          if (requests == 2) return rejected(429, 'M_LIMIT_EXCEEDED');
          return http.Response(
            jsonEncode({
              'access_token': 'phone-access-new',
              'refresh_token': 'phone-refresh-new',
              'expires_in_ms': 3600000,
            }),
            200,
          );
        }),
      );
      SessionDiagnostics.qrStarted(phone);
      final states = <LoginState>[];
      final sub = phone.onLoginStateChanged.stream.listen(states.add);
      addTearDown(sub.cancel);
      for (var i = 0; i < 3; i++) {
        await phone.ensureNotSoftLoggedOut();
        expect(db.clears, 0);
        expect(phone.isLogged(), isTrue);
        expect(phone.deviceID, 'PHONE');
      }
      await Future<void>.delayed(Duration.zero);
      expect(requests, 3);
      expect(phone.accessToken, 'phone-access-new');
      expect(db.row!['refresh_token'], 'phone-refresh-new');
      expect(states, isNot(contains(LoginState.loggedOut)));
      expect(states.last, LoginState.loggedIn);
    },
  );

  for (final code in [
    'M_UNKNOWN_TOKEN',
    'M_MISSING_TOKEN',
    'M_FORBIDDEN',
    'M_USER_DEACTIVATED',
  ]) {
    test(
      'explicit credential rejection $code still clears the rejected session',
      () async {
        final db = _MemoryDatabase();
        final phone = _Phone(db, MockClient((_) async => rejected(401, code)));
        await expectLater(
          phone.ensureNotSoftLoggedOut(),
          throwsA(isA<MatrixException>()),
        );
        expect(db.clears, 1);
        expect(phone.isLogged(), isFalse);
      },
    );
  }

  test(
    'network loss keeps phone session and a later attempt can refresh',
    () async {
      final db = _MemoryDatabase();
      var attempts = 0;
      final phone = _Phone(
        db,
        MockClient((_) async {
          if (++attempts == 1) throw http.ClientException('offline');
          return http.Response(
            '{"access_token":"restored","refresh_token":"rotated"}',
            200,
          );
        }),
      );
      await phone.ensureNotSoftLoggedOut();
      expect(db.clears, 0);
      await phone.ensureNotSoftLoggedOut();
      expect(phone.accessToken, 'restored');
      expect(db.clears, 0);
    },
  );

  test('logout diagnostics remain after SDK clears the log buffer', () async {
    final phone = _Phone(
      _MemoryDatabase(),
      MockClient((_) async => rejected(401, 'M_UNKNOWN_TOKEN')),
    );
    SessionDiagnostics.attach(phone);
    SessionDiagnostics.qrStarted(phone);
    await phone.clear(reason: SessionClearReason.unknownToken);
    await Future<void>.delayed(Duration.zero);
    final report = Logs().outputEvents
        .map((event) => event.toFormattedString())
        .join('\n');
    expect(report, contains('unknownToken'));
    expect(report, contains('seconds since QR:'));
    expect(report, isNot(contains('phone-access')));
    expect(report, isNot(contains('phone-refresh')));
  });
}
