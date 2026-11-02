// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cupertino_ui/cupertino_ui.dart'
    show GlobalCupertinoLocalizations;
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/l10n/l10n_en.dart';
import 'package:fluffychat/l10n/l10n_zh.dart';
import 'package:fluffychat/pages/new_private_chat/qr_login_dialog.dart';
import 'package:fluffychat/utils/qr_login/msc4108_channel.dart';
import 'package:fluffychat/utils/qr_login/qr_login_existing_device.dart';
import 'package:fluffychat/utils/qr_login/qr_login_payload.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

class _Account extends QrLoginAccount {
  bool unlocked = false;
  @override
  String get userId => '@alice:example.org';
  @override
  Future<QrLoginAuthMetadata> authMetadata() async => QrLoginAuthMetadata(
    Uri.parse('https://auth.example/'),
    supportsDeviceGrant: true,
  );
  @override
  Future<bool> deviceExists(String deviceId) async => false;
  @override
  Future<void> ensureSecretsAvailable() async {}
  @override
  Future<Map<String, Object?>> exportSecrets() async => {};
  @override
  Future<void> unlockSecrets(String value) async {
    if (value != 'synthetic-recovery') {
      throw const QrLoginException('keys_locked');
    }
    unlocked = true;
  }
}

class _Flow extends QrLoginExistingDevice {
  bool started = false;
  bool cancelled = false;
  bool shared = false;
  String? failWith;
  bool needsRecovery = false;
  final finish = Completer<void>();

  _Flow()
    : super(
        account: _Account(),
        payload: QrLoginPayload.fromBytes([
          ...ascii.encode('MATRIX'),
          2,
          3,
          ...List.filled(32, 1),
          0,
          'https://example.org/test'.length,
          ...utf8.encode('https://example.org/test'),
        ]),
        channel: Msc4108Channel(
          Msc4108Transport(
            Uri.parse('https://example.org/test'),
            httpClient: MockClient((_) async => http.Response('', 500)),
          ),
        ),
      );

  @override
  void cancel() {
    cancelled = true;
    super.cancel();
  }

  @override
  Future<void> run({
    required Future<bool> Function(String code) confirmCode,
    required Future<bool> Function(Uri uri, String deviceId) authorize,
    required void Function() onSharingSecrets,
    Future<bool> Function()? unlockSecrets,
  }) async {
    started = true;
    if (failWith != null) throw QrLoginException(failWith!);
    if (needsRecovery && (unlockSecrets == null || !await unlockSecrets())) {
      return;
    }
    if (!await confirmCode('42') || cancelled) return;
    if (!await authorize(
          Uri.parse('https://auth.example/verify?user_code=TEST'),
          'SYNTHETIC_NEW_DEVICE',
        ) ||
        cancelled) {
      return;
    }
    await finish.future;
    if (cancelled) return;
    onSharingSecrets();
    shared = true;
  }
}

class _TestL10nDelegate extends LocalizationsDelegate<L10n> {
  const _TestL10nDelegate();
  @override
  bool isSupported(Locale locale) => ['en', 'zh'].contains(locale.languageCode);
  @override
  Future<L10n> load(Locale locale) =>
      SynchronousFuture(locale.languageCode == 'zh' ? L10nZh() : L10nEn());
  @override
  bool shouldReload(_TestL10nDelegate old) => false;
}

Future<void> _openDialog(
  WidgetTester tester,
  _Flow flow, {
  Future<bool> Function(Uri)? open,
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: const Key('qr-login-qa-root'),
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: [
          const _TestL10nDelegate(),
          ...GlobalMaterialLocalizations.delegates,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        supportedLocales: L10n.supportedLocales,
        theme: ThemeData(
          platform: TargetPlatform.android,
          fontFamily:
              Platform.environment.containsKey('QR_LOGIN_SCREENSHOT_FONT')
              ? 'QrLoginQA'
              : null,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) =>
                    QrLoginDialog(flow: flow, openAuthorization: open),
              ),
              child: const Text('Scan'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Scan'));
  await tester.pumpAndSettle();
}

Future<void> _snapshot(WidgetTester tester, String name) async {
  final folder = Platform.environment['QR_LOGIN_SCREENSHOT_DIR'];
  if (folder == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('qr-login-qa-root')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(folder).create(recursive: true);
    await File('$folder/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = Platform.environment['QR_LOGIN_SCREENSHOT_FONT'];
    if (font != null) {
      final loader = FontLoader('QrLoginQA')
        ..addFont(
          Future.value(ByteData.sublistView(await File(font).readAsBytes())),
        );
      await loader.load();
    }
  });
  testWidgets('local recovery can retry; input is cleared before code check', (
    tester,
  ) async {
    final flow = _Flow()..needsRecovery = true;
    await _openDialog(tester, flow);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    await _snapshot(tester, 'unlock');
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    await tester.enterText(field, 'wrong');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text('42'), findsNothing);
    expect(find.textContaining('Incorrect'), findsOneWidget);
    await tester.enterText(field, 'synthetic-recovery');
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('42'), findsOneWidget);
    expect((flow.account as _Account).unlocked, isTrue);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('no handshake before consent; dismissing cancels', (
    tester,
  ) async {
    final flow = _Flow();
    await _openDialog(tester, flow);
    expect(find.text('@alice:example.org'), findsOneWidget);
    expect(flow.started, isFalse);
    await _snapshot(tester, 'consent');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(flow.cancelled, isTrue);
    expect(flow.shared, isFalse);
  });

  testWidgets(
    'code check gates browser; authorization and completion states work',
    (tester) async {
      final flow = _Flow();
      var opened = 0;
      await _openDialog(
        tester,
        flow,
        open: (uri) async {
          opened++;
          return true;
        },
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('42'), findsOneWidget);
      await _snapshot(tester, 'check-code');
      expect(opened, 0);
      await tester.tap(find.text('The codes match'));
      await tester.pumpAndSettle();
      expect(find.text('auth.example'), findsOneWidget);
      await _snapshot(tester, 'authorization');
      await tester.tap(find.text('Open authorization page'));
      await tester.pump();
      expect(opened, 1);
      expect(
        find.textContaining('Complete approval in your browser'),
        findsOneWidget,
      );
      flow.finish.complete();
      await tester.pumpAndSettle();
      expect(flow.shared, isTrue);
      await _snapshot(tester, 'success');
      expect(find.text('Close'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('browser failure can retry without authorizing or sending keys', (
    tester,
  ) async {
    final flow = _Flow();
    await _openDialog(tester, flow, open: (_) async => false);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('The codes match'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open authorization page'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Could not open the authorization page'),
      findsOneWidget,
    );
    expect(flow.shared, isFalse);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(flow.cancelled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Chinese keys-locked error remains usable on narrow screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final flow = _Flow()..failWith = 'keys_locked';
    await _openDialog(tester, flow, locale: const Locale('zh'));
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(find.textContaining('手机尚未验证'), findsOneWidget);
    await _snapshot(tester, 'keys-error-zh');
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('timeout releases pending confirmation and stops login', (
    tester,
  ) async {
    final flow = _Flow();
    await _openDialog(tester, flow);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('The login request has expired'),
      findsOneWidget,
    );
    expect(flow.cancelled, isTrue);
    expect(flow.shared, isFalse);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
