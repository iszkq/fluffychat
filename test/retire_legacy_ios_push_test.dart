// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/retire_legacy_ios_push.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Client implements Client {
  @override
  String get userID => '@alice:example.org';
  @override
  String get deviceID => 'THIS_DEVICE';
  @override
  String get clientName => 'Alice';

  final removed = <String>[];
  bool fail = false;

  @override
  Future<List<Pusher>?> getPushers() async => [
    for (final pair in [
      ('chat.fluffy.fluffychat.THIS_DEVICE', 'ntfy:old-topic'),
      ('chat.fluffy.fluffychat.OTHER_DEVICE', 'ntfy:old-topic'),
      ('chat.fluffy.fluffychat.THIS_DEVICE', 'fcm-token'),
    ])
      Pusher(
        appId: pair.$1,
        pushkey: pair.$2,
        kind: 'http',
        appDisplayName: 'FluffyChat',
        deviceDisplayName: 'iOS',
        lang: 'en',
        data: PusherData(url: Uri.parse('https://example.org/push')),
      ),
  ];

  @override
  Future<void> deletePusher(PusherId pusher) async {
    if (fail) throw StateError('offline');
    removed.add(pusher.pushkey);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const topicKey = 'chat.fluffy.ntfy_topic.Alice.@alice:example.org';
  const noticeKey =
      'chat.fluffy.ntfy_topic_notice_shown.Alice.@alice:example.org';
  setUp(
    () => SharedPreferences.setMockInitialValues({
      topicKey: 'old-topic',
      noticeKey: true,
    }),
  );

  test(
    'removes only this installations old relay registration and local settings',
    () async {
      final client = _Client();
      final store = await SharedPreferences.getInstance();
      await retireLegacyIosPush(client, store);
      expect(client.removed, ['ntfy:old-topic']);
      expect(store.containsKey(topicKey), isFalse);
      expect(store.containsKey(noticeKey), isFalse);
      await retireLegacyIosPush(client, store);
      expect(client.removed, hasLength(1));
    },
  );

  test(
    'retains migration markers if unregistering fails and retries later',
    () async {
      final client = _Client()..fail = true;
      final store = await SharedPreferences.getInstance();
      await expectLater(retireLegacyIosPush(client, store), throwsStateError);
      expect(store.getString(topicKey), 'old-topic');
      client.fail = false;
      await retireLegacyIosPush(client, store);
      expect(client.removed, ['ntfy:old-topic']);
    },
  );
}
