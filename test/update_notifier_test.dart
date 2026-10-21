// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/show_update_snackbar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> openUpdate(
    WidgetTester tester, {
    String? previous,
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    SharedPreferences.setMockInitialValues({
      UpdateNotifier.versionStoreKey: ?previous,
    });
    PackageInfo.setMockInitialValues(
      appName: 'FluffyChat',
      packageName: 'im.fluffychat.app',
      version: '2.11.1',
      buildNumber: '300037',
      buildSignature: '',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        locale: const Locale('zh'),
        localizationsDelegates: [
          ...L10n.localizationsDelegates,
          ...GlobalMaterialLocalizations.delegates,
          ...GlobalCupertinoLocalizations.delegates,
        ],
        supportedLocales: L10n.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => UpdateNotifier.showUpdateDialog(context),
              child: const Text('Check update'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check update'));
    await tester.pumpAndSettle();
  }

  testWidgets('first installation records build without an update dialog', (
    tester,
  ) async {
    await openUpdate(tester);
    expect(find.text('已更新至 2.11.1+300037'), findsNothing);
    final store = await SharedPreferences.getInstance();
    expect(store.getString(UpdateNotifier.versionStoreKey), '2.11.1+300037');
  });

  testWidgets('same installed build does not show an update dialog', (
    tester,
  ) async {
    await openUpdate(tester, previous: '2.11.1+300037');
    expect(find.text('已更新至 2.11.1+300037'), findsNothing);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('upgrade has fork description and two actions on $platform', (
      tester,
    ) async {
      // Migrate an existing installation that only recorded the version.
      await openUpdate(tester, previous: '2.11.1', platform: platform);
      expect(find.text('已更新至 2.11.1+300037'), findsOneWidget);
      expect(find.textContaining('iszkq/fluffychat'), findsOneWidget);
      expect(find.text('更新记录'), findsOneWidget);
      expect(find.text('关闭'), findsOneWidget);
      expect(find.text('支持'), findsNothing);
      expect(find.byIcon(Icons.favorite), findsNothing);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check update'));
      await tester.pumpAndSettle();
      expect(find.text('已更新至 2.11.1+300037'), findsNothing);
    });
  }

  testWidgets('a new build of the same version shows an update', (
    tester,
  ) async {
    await openUpdate(tester, previous: '2.11.1+300036');
    expect(find.text('已更新至 2.11.1+300037'), findsOneWidget);
  });
}
