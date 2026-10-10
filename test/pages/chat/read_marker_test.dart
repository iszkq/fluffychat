// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/pages/chat/chat.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/test_client.dart';

class _ReadTimeline implements Timeline {
  @override
  final List<Event> events;
  final requests = <String>[];
  final pending = <Completer<void>>[];

  _ReadTimeline(this.events);

  @override
  Future<void> setReadMarker({String? eventId, bool? public}) {
    requests.add(eventId!);
    final request = Completer<void>();
    pending.add(request);
    return request.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReadController extends ChatController {
  @override
  final Room room;

  _ReadController(this.room);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  testWidgets('deduplicates one event while allowing a newer read request', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final room = Room(
      id: '!room:example.org',
      client: await prepareTestClient(id: 'read-marker'),
    );
    final timeline = _ReadTimeline([
      Event(
        eventId: '\$first:example.org',
        type: EventTypes.Message,
        senderId: '@alice:example.org',
        originServerTs: DateTime.now(),
        content: {'body': 'First', 'msgtype': MessageTypes.Text},
        room: room,
      ),
    ]);
    final controller = _ReadController(room)..timeline = timeline;

    controller.setReadMarker(eventId: '\$first:example.org');
    controller.setReadMarker(eventId: '\$first:example.org');
    controller.setReadMarker(eventId: '\$second:example.org');
    expect(timeline.requests, ['\$first:example.org', '\$second:example.org']);

    timeline.pending.first.complete();
    await tester.pump();
    controller.setReadMarker(eventId: '\$second:example.org');
    expect(timeline.requests, hasLength(2));

    timeline.pending.last.complete();
    await tester.pump();
    controller.scrollController.dispose();
  });

  testWidgets('retries the same read marker after a failed request', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final room = Room(
      id: '!room:example.org',
      client: await prepareTestClient(id: 'read-marker'),
    );
    final timeline = _ReadTimeline([
      Event(
        eventId: '\$first:example.org',
        type: EventTypes.Message,
        senderId: '@alice:example.org',
        originServerTs: DateTime.now(),
        content: {'body': 'First', 'msgtype': MessageTypes.Text},
        room: room,
      ),
    ]);
    final controller = _ReadController(room)..timeline = timeline;

    controller.setReadMarker(eventId: '\$first:example.org');
    timeline.pending.single.completeError(StateError('offline'));
    await tester.pump();
    controller.setReadMarker(eventId: '\$first:example.org');
    expect(timeline.requests, ['\$first:example.org', '\$first:example.org']);
    timeline.pending.last.complete();
    await tester.pump();
    controller.scrollController.dispose();
  });
}
