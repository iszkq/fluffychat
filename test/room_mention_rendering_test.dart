// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/events/html_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Client implements Client {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
  });
  final room = Room(id: '!group:example.org', client: _Client());

  Future<void> render(WidgetTester tester, String html, bool mention) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: [
          ...L10n.localizationsDelegates,
          ...GlobalMaterialLocalizations.delegates,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: HtmlMessage(
            html: html,
            roomMention: mention,
            room: room,
            fontSize: 16,
            linkStyle: const TextStyle(color: Colors.blue),
            onOpen: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final html in [
    '@room ',
    '<a href="https://matrix.to/#/!group:example.org">@room </a>',
    '@room请看',
  ]) {
    testWidgets('renders a real all-members mention: $html', (tester) async {
      await render(tester, html, true);
      expect(find.byKey(const ValueKey('room_mention_pill')), findsOneWidget);
      expect(find.text('@全体成员'), findsOneWidget);
    });
  }
  testWidgets('ordinary text is never shown as a successful mention', (
    tester,
  ) async {
    await render(tester, '@room ', false);
    expect(find.byKey(const ValueKey('room_mention_pill')), findsNothing);
  });
  testWidgets('quoted text, code, URLs and Matrix IDs stay literal', (
    tester,
  ) async {
    await render(
      tester,
      '<blockquote>@room</blockquote><code>@room</code>'
      '<a href="https://example.org">@room</a>'
      ' mail@room.example.org @room:example.org',
      true,
    );
    expect(find.byKey(const ValueKey('room_mention_pill')), findsNothing);
  });
}
