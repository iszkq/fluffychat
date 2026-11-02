// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:fluffychat/utils/qr_login/matrix_qr_login_account.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';

// Use the real SDK request/cache path; any database access fails this test.
class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SdkClient extends Client {
  _SdkClient(http.Client transport)
    : super('qr-test', database: _UnusedDatabase(), httpClient: transport) {
    homeserver = Uri.parse('https://matrix.example');
  }

  @override
  String get userID => '@alice:matrix.example';
  @override
  String get deviceID => 'PHONE';
  @override
  bool isLogged() => true;
}

GetAuthMetadataResponse metadata(String origin) =>
    GetAuthMetadataResponse.fromJson({
      'issuer': '$origin/',
      'authorization_endpoint': '$origin/oauth2/auth',
      'device_authorization_endpoint': '$origin/oauth2/device',
      'token_endpoint': '$origin/oauth2/token',
      'registration_endpoint': '$origin/oauth2/register',
      'revocation_endpoint': '$origin/oauth2/revoke',
      'code_challenge_methods_supported': ['S256'],
      'grant_types_supported': ['urn:ietf:params:oauth:grant-type:device_code'],
      'response_modes_supported': ['query'],
      'response_types_supported': ['code'],
    });

class _Client implements Client {
  bool offline = false;

  @override
  String get userID => '@alice:example.org';
  @override
  String get deviceID => 'PHONE';
  @override
  bool isLogged() => true;

  @override
  Future<GetAuthMetadataResponse> getAuthMetadata({
    Duration cacheLifetime = const Duration(days: 3),
    bool throwOnUpdateFailure = false,
  }) async {
    // Emulate the SDK's current cache behavior: a prior issuer can remain
    // available for three days and can be reused when refreshing fails.
    if (cacheLifetime != Duration.zero || (offline && !throwOnUpdateFailure)) {
      return metadata('https://old-auth.example');
    }
    if (offline) throw StateError('network unavailable');
    return metadata('https://current-auth.example');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'real SDK fetches current metadata on every QR attempt without cached storage',
    () async {
      var requests = 0;
      final client = _SdkClient(
        MockClient((request) async {
          expect(request.url.path, '/_matrix/client/v1/auth_metadata');
          requests++;
          return http.Response(
            jsonEncode(metadata('https://auth-$requests.example').toJson()),
            200,
          );
        }),
      );
      expect(
        (await MatrixQrLoginAccount(client).authMetadata()).issuer.host,
        'auth-1.example',
      );
      expect(
        (await MatrixQrLoginAccount(client).authMetadata()).issuer.host,
        'auth-2.example',
      );
      expect(requests, 2);
    },
  );

  test(
    'QR account reads the current issuer instead of the SDK cache',
    () async {
      final account = MatrixQrLoginAccount(_Client());
      final result = await account.authMetadata();
      expect(result.issuer, Uri.parse('https://current-auth.example/'));
      expect(result.supportsDeviceGrant, isTrue);
    },
  );

  test(
    'failed metadata refresh cannot silently trust the previous issuer',
    () async {
      final account = MatrixQrLoginAccount(_Client()..offline = true);
      await expectLater(account.authMetadata(), throwsStateError);
    },
  );
}
