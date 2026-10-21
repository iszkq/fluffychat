// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/matrix_sdk_extensions/room_mention_extension.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

class _MentionClient extends Client {
  _MentionClient() : super('Room mention tests');

  @override
  String get userID => '@sender:example.org';
}

// Use the real pinned SDK's command, Markdown and mention processing, capturing
// its content at the sendEvent boundary without contacting a homeserver.
class _MentionRoom extends Room {
  _MentionRoom() : super(id: '!mentions:example.org', client: _MentionClient());

  bool allowed = true;
  Map<String, dynamic>? sentContent;
  Event? sentReply;
  String? sentEdit;
  String? sentThread;

  @override
  bool canSendNotification(String userid, {String notificationType = 'room'}) =>
      userid == client.userID && allowed;

  @override
  String? getMention(String mention) =>
      mention == '@[张三]' ? '@zhang:example.org' : null;

  @override
  Future<String?> sendEvent(
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
  }) async {
    sentContent = content;
    sentReply = inReplyTo;
    sentEdit = editEventId;
    sentThread = threadRootEventId;
    return r'$sent';
  }

  Map<String, dynamic> get mentions =>
      sentContent?['m.mentions'] as Map<String, dynamic>? ?? {};
}

void main() {
  late _MentionRoom room;
  setUp(() => room = _MentionRoom());
  tearDown(() => room.client.dispose());

  test('reproduces the SDK missing a room mention next to Chinese', () async {
    await room.sendTextEvent('@room请看');
    expect(room.mentions['room'], isNot(true));
  });

  for (final message in [
    '@room',
    '@room ', // The suggestion list inserts this exact string.
    '@room 请看',
    '@room请看',
    '请@room看一下',
    '@room，通知大家',
    '@room! Hello',
    '@room.',
    '@room\n请看',
  ]) {
    test('sends a real room mention for $message', () async {
      await room.sendTextWithRoomMentions(message);
      expect(room.mentions['room'], isTrue);
    });
    test('never pings the room without permission for $message', () async {
      room.allowed = false;
      await room.sendTextWithRoomMentions(message);
      expect(room.mentions['room'], isNot(true));
      expect(room.sentContent!['body'], isNot(contains('@room')));
    });
  }

  test('preserves a Chinese personal mention alongside the room', () async {
    await room.sendTextWithRoomMentions('@room请看 @[张三]');
    expect(room.mentions, {
      'room': true,
      'user_ids': ['@zhang:example.org'],
    });
  });

  test('personal mentions still work without room permission', () async {
    room.allowed = false;
    await room.sendTextWithRoomMentions('@room请看 @[张三]');
    expect(room.mentions, {
      'user_ids': ['@zhang:example.org'],
    });
  });

  test('preserves direct Matrix IDs and excludes the sender', () async {
    await room.sendTextWithRoomMentions(
      '@room @alice:example.org @sender:example.org',
    );
    expect(room.mentions, {
      'room': true,
      'user_ids': ['@alice:example.org'],
    });
  });

  test('does not interpret a room-named user as the entire room', () async {
    for (final allowed in [true, false]) {
      room.allowed = allowed;
      await room.sendTextWithRoomMentions('@room:example.org');
      expect(room.sentContent!['body'], '@room:example.org');
      expect(room.mentions, {
        'user_ids': ['@room:example.org'],
      });
    }
  });

  for (final message in [
    '@roommate',
    '@rooms',
    'mail@room.example.org',
    '@[room] 请看',
  ]) {
    test('leaves other text unchanged: $message', () async {
      await room.sendTextWithRoomMentions(message);
      expect(room.sentContent!['body'], message);
      expect(room.mentions['room'], isNot(true));
    });
  }

  test('preserves reply mentions and edit/thread arguments', () async {
    final reply = Event.fromJson({
      'event_id': r'$reply',
      'sender': '@alice:example.org',
      'type': EventTypes.Message,
      'content': {'body': 'Hello', 'msgtype': MessageTypes.Text},
    }, room);
    await room.sendTextWithRoomMentions(
      '@room请看',
      inReplyTo: reply,
      editEventId: r'$edit',
      threadRootEventId: r'$thread',
    );
    expect(room.mentions, {
      'room': true,
      'user_ids': ['@alice:example.org'],
    });
    expect(room.sentReply, same(reply));
    expect(room.sentEdit, r'$edit');
    expect(room.sentThread, r'$thread');
  });

  test('keeps Markdown formatting', () async {
    await room.sendTextWithRoomMentions('@room **请看**');
    expect(room.mentions['room'], isTrue);
    expect(
      room.sentContent!['formatted_body'],
      contains('<strong>请看</strong>'),
    );
  });

  for (final command in ['send', 'me', 'plain']) {
    test('preserves /$command behavior and enforces permission', () async {
      await room.sendTextWithRoomMentions('/$command @room请看');
      expect(room.mentions['room'], isTrue);
      expect(room.sentContent!['body'], '@room 请看');
      expect(
        room.sentContent!['msgtype'],
        command == 'me' ? MessageTypes.Emote : MessageTypes.Text,
      );
      room.allowed = false;
      await room.sendTextWithRoomMentions('/$command @room请看');
      expect(room.mentions['room'], isNot(true));
    });
  }

  test('respects sending an unknown command as plain text', () async {
    await room.sendTextWithRoomMentions(
      '/unknown @room请看',
      parseCommands: false,
    );
    expect(room.sentContent!['body'], '/unknown @room 请看');
    expect(room.mentions['room'], isTrue);
  });
}
