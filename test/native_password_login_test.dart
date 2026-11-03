// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/login/login.dart';
import 'package:fluffychat/pages/sign_in/view_model/model/public_homeserver_data.dart';
import 'package:fluffychat/utils/sign_in_flows/check_homeserver.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LoginClient extends Client {
  final calls = <String>[];
  bool reject = true;
  bool authenticated = false;
  _LoginClient()
    : super(
        'selected-login-client',
        database: _UnusedDatabase(),
        httpClient: MockClient((request) async {
          switch (request.url.path) {
            case '/.well-known/matrix/client':
              return http.Response(
                jsonEncode({
                  'm.homeserver': {'base_url': 'https://matrix.example.org'},
                }),
                200,
              );
            case '/_matrix/client/versions':
              return http.Response(
                jsonEncode({
                  'versions': ['v1.14'],
                }),
                200,
              );
            case '/_matrix/client/v3/login':
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
            default:
              return http.Response(
                jsonEncode({'errcode': 'M_NOT_FOUND', 'error': 'not found'}),
                404,
              );
          }
        }),
      );
  @override
  String get userID => '@alice:example.org';
  @override
  String get deviceID => 'PHONE';
  @override
  bool isLogged() => authenticated;
  @override
  Future<LoginResponse> login(
    String type, {
    AuthenticationIdentifier? identifier,
    String? password,
    String? token,
    String? deviceId,
    String? initialDeviceDisplayName,
    bool? refreshToken,
    String? user,
    String? medium,
    String? address,
    void Function(InitState)? onInitStateChanged,
  }) async {
    calls.add(type);
    expect(homeserver?.host, 'matrix.example.org');
    expect(identifier, isA<AuthenticationUserIdentifier>());
    expect(password, 'synthetic-password');
    if (reject) {
      throw MatrixException.fromJson({
        'errcode': 'M_FORBIDDEN',
        'error': 'synthetic-password-rejected',
      });
    }
    authenticated = true;
    return LoginResponse(
      accessToken: 'synthetic-token',
      deviceId: deviceID,
      userId: userID,
    );
  }
}

class _Matrix extends MatrixState {
  @override
  final Client client;
  int loginClientRequests = 0;
  _Matrix(this.client);
  @override
  Future<Client> getLoginClient() async {
    loginClientRequests++;
    if (loginClientRequests > 1) {
      throw StateError('Login must use the discovered client');
    }
    return client;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  testWidgets(
    'server selection opens native login, shows password error, retries with the same client and enters recovery',
    (tester) async {
      final client = _LoginClient();
      final matrix = _Matrix(client);
      final router = GoRouter(
        initialLocation: '/home',
        routes: [
          GoRoute(
            path: '/home',
            builder: (context, _) => Scaffold(
              body: TextButton(
                onPressed: () => connectToHomeserverFlow(
                  PublicHomeserverData(name: 'example.org'),
                  context,
                  (_) {},
                  false,
                ),
                child: const Text('connect-server'),
              ),
            ),
          ),
          GoRoute(
            path: '/home/login',
            builder: (_, state) => Login(client: state.extra! as Client),
          ),
          GoRoute(
            path: '/backup',
            builder: (_, _) => const Scaffold(body: Text('recovery-ready')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: matrix,
          child: MaterialApp.router(
            routerConfig: router,
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('connect-server'));
      await tester.pumpAndSettle();
      expect(find.byType(Login), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2));
      final controller = tester.state<LoginController>(find.byType(Login));
      controller.usernameController.text = '@alice:example.org';
      controller.passwordController.text = 'synthetic-password';
      await controller.login();
      await tester.pump();
      expect(find.text('synthetic-password-rejected'), findsOneWidget);
      expect(controller.loading, isFalse);
      client.reject = false;
      await controller.login();
      await tester.pumpAndSettle();
      expect(find.text('recovery-ready'), findsOneWidget);
      expect(client.calls, [
        LoginType.mLoginPassword,
        LoginType.mLoginPassword,
      ]);
      expect(matrix.loginClientRequests, 1);
      client.onLoginStateChanged.add(LoginState.loggedOut);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
