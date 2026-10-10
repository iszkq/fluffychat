// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/push_helper.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

class _Notifications implements FlutterLocalNotificationsPlugin {
  final List<ActiveNotification> active;
  final cancelled = <int>[];
  final shown = <int>[];
  NotificationDetails? details;

  _Notifications(this.active);

  @override
  Future<List<ActiveNotification>> getActiveNotifications() async => active;

  @override
  Future<void> cancel({required int id, String? tag}) async =>
      cancelled.add(id);

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    shown.add(id);
    details = notificationDetails;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late L10n l10n;
  setUp(() async => l10n = await L10n.delegate.load(const Locale('en')));

  test(
    'keeps a summary for a single child and ignores another account',
    () async {
      final notifications = _Notifications([
        ActiveNotification(id: 10, groupKey: 'account', body: 'New message'),
        ActiveNotification(id: 20, groupKey: 'other', body: 'Other account'),
      ]);
      await updateSummaryNotification(
        flutterLocalNotificationsPlugin: notifications,
        clientName: 'account',
        l10n: l10n,
      );
      expect(notifications.cancelled, isEmpty);
      expect(notifications.shown, ['account'.hashCode]);
      expect(notifications.details!.android!.silent, isTrue);
      final style =
          notifications.details!.android!.styleInformation
              as InboxStyleInformation;
      expect(style.lines, ['New message']);
    },
  );

  test('updates an existing summary without counting it as a child', () async {
    final notifications = _Notifications([
      ActiveNotification(
        id: 'account'.hashCode,
        groupKey: 'account',
        body: 'Summary',
      ),
      ActiveNotification(id: 10, groupKey: 'account', body: 'New message'),
    ]);
    await updateSummaryNotification(
      flutterLocalNotificationsPlugin: notifications,
      clientName: 'account',
      l10n: l10n,
    );
    expect(notifications.shown, ['account'.hashCode]);
    final style =
        notifications.details!.android!.styleInformation
            as InboxStyleInformation;
    expect(style.lines, ['New message']);
  });

  test('removes only this account summary when no children remain', () async {
    final notifications = _Notifications([
      ActiveNotification(id: 'account'.hashCode, groupKey: 'account'),
      ActiveNotification(id: 20, groupKey: 'other'),
    ]);
    await updateSummaryNotification(
      flutterLocalNotificationsPlugin: notifications,
      clientName: 'account',
      l10n: l10n,
    );
    expect(notifications.shown, isEmpty);
    expect(notifications.cancelled, ['account'.hashCode]);
  });
}
