// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Serializes startup delivery and permits a fresh Activity to open a new tap.
class NotificationLaunchHandler {
  bool _handled = false;
  int _generation = 0;
  Future<void>? _pending;

  void reset() {
    _generation++;
    _handled = false;
  }

  Future<void> handle({
    required Future<NotificationAppLaunchDetails?> Function() load,
    required Future<void> Function(NotificationResponse) open,
  }) async {
    while (_pending != null) {
      await _pending;
    }
    if (_handled) return;
    final operation = _handle(load: load, open: open);
    _pending = operation;
    try {
      await operation;
    } finally {
      _pending = null;
    }
  }

  Future<void> _handle({
    required Future<NotificationAppLaunchDetails?> Function() load,
    required Future<void> Function(NotificationResponse) open,
  }) async {
    final generation = _generation;
    final details = await load();
    final response = details?.notificationResponse;
    if (details?.didNotificationLaunchApp != true || response == null) return;
    await open(response);
    if (generation == _generation) _handled = true;
  }
}
