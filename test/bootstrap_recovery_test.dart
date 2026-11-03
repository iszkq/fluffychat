// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/bootstrap/bootstrap_page.dart';
import 'package:fluffychat/pages/bootstrap/widgets/restore_bootstrap_view.dart';
import 'package:fluffychat/pages/key_verification/key_verification_dialog.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/encryption/cross_signing.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backup implements KeyManager {
  final _Client owner;
  _Backup(this.owner);
  @override
  bool get enabled => true;
  @override
  Future<bool> isCached() async => owner.connected;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Signing implements CrossSigning {
  final _Client owner;
  _Signing(this.owner);
  @override
  bool get enabled => true;
  @override
  Future<bool> isCached() async => owner.connected;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Crypto implements Encryption {
  @override
  final _Client client;
  _Crypto(this.client);
  @override
  late final KeyManager keyManager = _Backup(client);
  @override
  late final CrossSigning crossSigning = _Signing(client);
  @override
  late final SSSS ssss = SSSS(this);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends Client {
  bool connected = false;
  bool offline = false;
  _Client() : super('recovery-test', database: _UnusedDatabase()) {
    for (final type in [
      EventTypes.MegolmBackup,
      EventTypes.CrossSigningMasterKey,
      EventTypes.CrossSigningSelfSigning,
      EventTypes.CrossSigningUserSigning,
    ]) {
      accountData[type] = BasicEvent(type: type, content: {});
    }
  }
  @override
  String get userID => '@alice:example.org';
  @override
  String get deviceID => 'PHONE';
  @override
  late final Encryption encryption = _Crypto(this);
  @override
  Future<void> updateUserDeviceKeys({Set<String>? additionalUsers}) async {
    if (offline) throw StateError('device-query-offline');
  }

  @override
  Future<Profile> getProfileFromUserId(
    String userId, {
    bool? getFromRooms,
    bool? cache,
    Duration maxCacheAge = const Duration(hours: 1),
    Duration timeout = const Duration(seconds: 10),
  }) async => Profile(userId: userId, displayName: 'Alice');
}

class _Matrix extends MatrixState {
  @override
  final Client client;
  _Matrix(this.client);
}

class _Request extends KeyVerification {
  int cancellations = 0;
  _Request(_Client client)
    : super(encryption: client.encryption, userId: client.userID);
  @override
  List<String> get sasTypes => ['decimal'];
  @override
  List<int> get sasNumbers => [1234, 5678, 9012];
  @override
  Future<void> cancel([String code = 'm.unknown', bool quiet = false]) async {
    cancellations++;
    state = KeyVerificationState.error;
    onUpdate?.call();
  }
}

class _Device implements DeviceKeys {
  @override
  final String deviceId;
  @override
  final bool blocked;
  final _Request request;
  int starts = 0;
  _Device(this.deviceId, this.request, {this.blocked = false});
  @override
  String get deviceDisplayName => 'Desktop $deviceId';
  @override
  DateTime get lastActive => DateTime(2026, 11, 3);
  @override
  bool hasValidSignatureChain({
    bool verifiedByTheirMasterKey = false,
    Set<String>? onlyValidateUserIds,
    bool verifiedOnly = true,
    Set<String>? visited,
  }) => false;
  @override
  Future<KeyVerification> startVerification() async {
    starts++;
    return request;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<GoRouter> _mountRecovery(WidgetTester tester, _Client client) async {
  final router = GoRouter(
    initialLocation: '/backup',
    routes: [
      GoRoute(
        path: '/backup',
        builder: (_, _) => const BootstrapPage(reset: false),
      ),
      GoRoute(
        path: '/rooms',
        builder: (_, _) => const Scaffold(body: Text('rooms-ready')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    Provider<MatrixState>.value(
      value: _Matrix(client),
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
  });

  testWidgets(
    'upstream recovery keeps device verification and key/file fallback when list is empty',
    (tester) async {
      final client = _Client();
      await _mountRecovery(tester, client);
      final context = tester.element(find.byType(RestoreBootstrapView));
      expect(find.text(L10n.of(context).verifyOtherDevice), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text(L10n.of(context).openFile), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'other own device remains selectable without a master signature; blocked/current devices hidden',
    (tester) async {
      final client = _Client();
      final request = _Request(client);
      final desktop = _Device('PC', request);
      client.userDeviceKeys[client.userID] = DeviceKeysList(
        client.userID,
        client,
        deviceKeys: {
          'PC': desktop,
          'PHONE': _Device('PHONE', request),
          'BLOCKED': _Device('BLOCKED', request, blocked: true),
        },
      );
      await _mountRecovery(tester, client);
      expect(find.text('Desktop PC'), findsOneWidget);
      expect(find.text('Desktop PHONE'), findsNothing);
      expect(find.text('Desktop BLOCKED'), findsNothing);
      await tester.tap(find.text('Desktop PC'));
      await tester.pump();
      expect(desktop.starts, 1);
      final model = tester
          .widget<RestoreBootstrapView>(find.byType(RestoreBootstrapView))
          .viewModel;
      expect(model.value.keyVerification, same(request));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'verification started elsewhere routes the real recovery page to rooms on secret arrival',
    (tester) async {
      final client = _Client();
      final router = await _mountRecovery(tester, client);
      client.connected = true;
      client.encryption.ssss.onSecretStored.add(
        EventTypes.CrossSigningSelfSigning,
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(router.routeInformationProvider.value.uri.path, '/rooms');
      expect(find.text('rooms-ready'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('keys arriving after timeout still enter rooms without restart', (
    tester,
  ) async {
    final client = _Client();
    final request = _Request(client);
    final desktop = _Device('PC', request);
    client.userDeviceKeys[client.userID] = DeviceKeysList(
      client.userID,
      client,
      deviceKeys: {'PC': desktop},
    );
    final router = await _mountRecovery(tester, client);
    await tester.tap(find.text('Desktop PC'));
    await tester.pump();
    request.state = KeyVerificationState.done;
    request.onUpdate?.call();
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    final model = tester
        .widget<RestoreBootstrapView>(find.byType(RestoreBootstrapView))
        .viewModel;
    expect(model.value.noSecretsreceived, isTrue);
    expect(model.value.waitingForSecrets, isFalse);
    client.connected = true;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(router.routeInformationProvider.value.uri.path, '/rooms');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'device discovery error stays visible across identity polling and retries',
    (tester) async {
      final client = _Client()..offline = true;
      await _mountRecovery(tester, client);
      expect(find.textContaining('device-query-offline'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('device-query-offline'), findsOneWidget);
      client.offline = false;
      final model = tester
          .widget<RestoreBootstrapView>(find.byType(RestoreBootstrapView))
          .viewModel;
      await model.refreshConnectedDevices();
      await tester.pump();
      expect(find.textContaining('device-query-offline'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('periodic updates do not stack SAS dialogs', (tester) async {
    final client = _Client();
    final request = _Request(client);
    client.userDeviceKeys[client.userID] = DeviceKeysList(
      client.userID,
      client,
      deviceKeys: {'PC': _Device('PC', request)},
    );
    await _mountRecovery(tester, client);
    await tester.tap(find.text('Desktop PC'));
    await tester.pump();
    request.state = KeyVerificationState.askSas;
    request.onUpdate?.call();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byType(KeyVerificationDialog, skipOffstage: false),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(
      find.byType(KeyVerificationDialog, skipOffstage: false),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
