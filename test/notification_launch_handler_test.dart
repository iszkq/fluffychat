// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/utils/notification_launch_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const response = NotificationResponse(
    notificationResponseType: NotificationResponseType.selectedNotification,
    payload: 'alice|!room:example.org|message',
  );

  test(
    'concurrent startup requests open once and a new activity can reopen',
    () async {
      final handler = NotificationLaunchHandler();
      final loaded = Completer<NotificationAppLaunchDetails?>();
      var opened = 0;
      Future<void> open(NotificationResponse _) async {
        opened++;
      }

      final pending = Future.wait([
        handler.handle(load: () => loaded.future, open: open),
        handler.handle(load: () => loaded.future, open: open),
      ]);
      loaded.complete(
        const NotificationAppLaunchDetails(
          true,
          notificationResponse: response,
        ),
      );
      await pending;
      expect(opened, 1);
      handler.reset();
      await handler.handle(load: () => loaded.future, open: open);
      expect(opened, 2);
    },
  );

  test('a failed navigation can retry', () async {
    final handler = NotificationLaunchHandler();
    Future<NotificationAppLaunchDetails?> load() async =>
        const NotificationAppLaunchDetails(
          true,
          notificationResponse: response,
        );
    await expectLater(
      handler.handle(
        load: load,
        open: (_) async {
          throw StateError('account still loading');
        },
      ),
      throwsStateError,
    );
    var opened = false;
    await handler.handle(
      load: load,
      open: (_) async {
        opened = true;
      },
    );
    expect(opened, isTrue);
  });

  test(
    'a normal startup does not consume a later notification launch',
    () async {
      final handler = NotificationLaunchHandler();
      var opened = 0;
      Future<void> open(NotificationResponse _) async {
        opened++;
      }

      await handler.handle(
        load: () async => const NotificationAppLaunchDetails(false),
        open: open,
      );
      await handler.handle(
        load: () async => const NotificationAppLaunchDetails(
          true,
          notificationResponse: response,
        ),
        open: open,
      );
      expect(opened, 1);
    },
  );
}
