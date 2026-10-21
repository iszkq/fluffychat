// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/app_config.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Upgrade cleanup only: stop the removed relay for this installation.
/// Failed requests retain the local marker so cleanup retries on next launch.
Future<void> retireLegacyIosPush(Client client, SharedPreferences store) async {
  final userId = client.userID;
  if (userId == null || client.deviceID == null) return;
  final suffix = '${client.clientName}.$userId';
  final topicKey = 'chat.fluffy.ntfy_topic.$suffix';
  final noticeKey = 'chat.fluffy.ntfy_topic_notice_shown.$suffix';
  final topic = store.getString(topicKey);
  if (topic == null) {
    await store.remove(noticeKey);
    return;
  }
  var appId = '${AppConfig.pushNotificationsAppId}.${client.deviceID}';
  if (appId.length > 64) appId = appId.substring(0, 64);
  final pushers =
      await client.getPushers().timeout(const Duration(seconds: 10)) ??
      <Pusher>[];
  for (final pusher in pushers) {
    if (pusher.appId == appId && pusher.pushkey == 'ntfy:${topic.trim()}') {
      await client.deletePusher(pusher).timeout(const Duration(seconds: 10));
    }
  }
  await store.remove(topicKey);
  await store.remove(noticeKey);
}
