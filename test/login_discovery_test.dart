// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'package:fluffychat/utils/sign_in_flows/login_discovery.dart';
import 'package:fluffychat/utils/sign_in_flows/sign_in_method.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:test/test.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'real SDK discovery selects app password login with OIDC and SSO present',
    () async {
      final requests = <String>[];
      final client = Client(
        'discovery-test',
        database: _UnusedDatabase(),
        httpClient: MockClient((request) async {
          requests.add(request.url.toString());
          final path = request.url.path;
          if (path == '/.well-known/matrix/client') {
            return http.Response(
              jsonEncode({
                'm.homeserver': {'base_url': 'https://matrix.example.org'},
              }),
              200,
            );
          }
          if (path == '/_matrix/client/versions') {
            return http.Response(
              jsonEncode({
                'versions': ['v1.14'],
              }),
              200,
            );
          }
          if (path == '/_matrix/client/v3/login') {
            expect(request.url.host, 'matrix.example.org');
            return http.Response(
              jsonEncode({
                'flows': [
                  {'type': 'm.login.password'},
                  {'type': 'm.login.sso', 'oauth_aware_preferred': true},
                  {'type': 'm.login.token'},
                ],
              }),
              200,
            );
          }
          if (path == '/_matrix/client/v1/auth_metadata') {
            return http.Response(
              jsonEncode({
                'issuer': 'https://account.example.org/',
                'authorization_endpoint':
                    'https://account.example.org/authorize',
                'token_endpoint': 'https://account.example.org/token',
                'registration_endpoint': 'https://account.example.org/register',
                'revocation_endpoint': 'https://account.example.org/revoke',
                'response_types_supported': ['code'],
                'response_modes_supported': ['query'],
                'grant_types_supported': ['authorization_code'],
                'code_challenge_methods_supported': ['S256'],
              }),
              200,
            );
          }
          throw StateError('Unexpected network request: $request');
        }),
      );
      final result = await discoverLoginMethod(
        client,
        Uri.parse('https://example.org'),
        signUp: false,
        enableOidc: true,
      );
      expect(result.method, SignInMethod.password);
      expect(client.homeserver, Uri.parse('https://matrix.example.org'));
      expect(requests.any((url) => url.contains('/v3/login')), isTrue);
      expect(requests.any((url) => url.contains('/auth_metadata')), isTrue);
      expect(requests.any((url) => url.contains('/authorize')), isFalse);
    },
  );

  test(
    'actual public server discovery chooses app login without authenticating',
    () async {
      final client = Client(
        'public-discovery-test',
        database: _UnusedDatabase(),
      );
      final result = await discoverLoginMethod(
        client,
        Uri.parse('https://mtx01.cc'),
        signUp: false,
        enableOidc: true,
      );
      expect(result.method, SignInMethod.password);
      expect(client.homeserver?.host, 'matrix.mtx01.cc');
    },
    skip: Platform.environment['VERIFY_PUBLIC_LOGIN_DISCOVERY'] != '1',
  );
}
