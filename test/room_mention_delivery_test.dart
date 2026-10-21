// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:fluffychat/utils/matrix_sdk_extensions/room_mention_extension.dart';
import 'package:fluffychat/utils/room_mention_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/encryption/encryption.dart';
import 'package:matrix/encryption/key_manager.dart';
import 'package:matrix/encryption/utils/outbound_group_session.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vodozemac/vodozemac.dart' as vod;

const _sender = '@sender:example.org';
const _roomId = '!group:example.org';

Event _permissions(Room room, {int senderLevel = 100}) => Event.fromJson({
  'type': EventTypes.RoomPowerLevels,
  'event_id': r'$permissions',
  'sender': '@owner:example.org',
  'state_key': '',
  'content': {
    'users': {_sender: senderLevel},
    'notifications': {'room': 50},
  },
}, room);

class _Database implements DatabaseApi {
  final saved = <StrippedStateEvent>[];
  int reads = 0;
  @override
  Future<void> transaction(Future<void> Function() action) => action();
  @override
  Future<List<Event>> getUnimportantRoomEventStatesForRoom(
    List<String> excluded,
    Room room,
  ) async {
    reads++;
    // Match the SDK's separate non-preloaded store and exclusion filter.
    return excluded.contains(EventTypes.RoomPowerLevels)
        ? []
        : [_permissions(room)];
  }

  @override
  Future<void> storeEventUpdate(
    String roomId,
    StrippedStateEvent event,
    EventUpdateType type,
    Client client,
  ) async => saved.add(event);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends Client {
  final String account;
  Encryption? testEncryption;
  _Client(this.account, DatabaseApi database, http.Client transport)
    : super(
        'mention-test',
        database: database,
        httpClient: transport,
        importantStateEvents: {EventTypes.RoomPowerLevels},
        sendTimelineEventTimeout: Duration.zero,
      ) {
    homeserver = Uri.parse('https://example.org');
    accessToken = 'test-only';
  }
  @override
  String get userID => account;
  @override
  String get deviceID => 'TEST';
  @override
  Encryption? get encryption => testEncryption;
}

class _Room extends Room {
  _Room(Client client) : super(id: _roomId, client: client);
  // Only suppress local database echoes: actual sendEvent, encryption and
  // sendMessage HTTP serialization are all executed, not replaced by a capture.
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
  }) => super.sendEvent(
    content,
    type: type,
    txid: txid,
    inReplyTo: inReplyTo,
    editEventId: editEventId,
    threadRootEventId: threadRootEventId,
    threadLastEventId: threadLastEventId,
    displayPendingEvent: false,
  );
}

class _Sessions implements KeyManager {
  final vod.GroupSession group = vod.GroupSession();
  late final outbound = OutboundGroupSession(
    devices: {},
    creationTime: DateTime.now(),
    outboundGroupSession: group,
    key: 'test',
  );
  @override
  OutboundGroupSession getOutboundGroupSession(String roomId) => outbound;
  @override
  Future<bool> clearOrUseOutboundGroupSession(
    String roomId, {
    bool wipe = false,
    bool use = true,
  }) async => false;
  @override
  Future<void> storeOutboundGroupSession(
    String roomId,
    OutboundGroupSession session,
  ) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Encryption extends Encryption {
  _Encryption(Client client) : super(client: client);
  final _Sessions sessions = _Sessions();
  @override
  KeyManager get keyManager => sessions;
  @override
  bool get enabled => true;
  @override
  String get identityKey => 'test-sender-key';
}

PushruleEvaluator _rules({bool enabled = true, bool muted = false}) =>
    PushruleEvaluator.fromRuleset(
      PushRuleSet(
        override: [
          if (muted)
            PushRule(
              ruleId: _roomId,
              default$: false,
              enabled: true,
              actions: [],
              conditions: [
                PushCondition(
                  kind: 'event_match',
                  key: 'room_id',
                  pattern: _roomId,
                ),
              ],
            ),
          PushRule(
            ruleId: '.m.rule.is_room_mention',
            default$: true,
            enabled: enabled,
            actions: [
              'notify',
              {'set_tweak': 'highlight', 'value': true},
            ],
            conditions: [
              PushCondition(
                kind: 'event_property_is',
                key: r'content.m\.mentions.room',
                value: true,
              ),
              PushCondition(
                kind: 'sender_notification_permission',
                key: 'room',
              ),
            ],
          ),
        ],
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Database database;
  late _Client sender;
  late _Client recipient;
  late _Room outgoing;
  late Room incoming;
  late Map<String, dynamic> wire;
  late Uri requestUri;

  setUp(() {
    database = _Database();
    final transport = MockClient((request) async {
      requestUri = request.url;
      wire = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({'event_id': r'$sent'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    sender = _Client(_sender, database, transport);
    recipient = _Client('@reader:example.org', database, transport);
    outgoing = _Room(sender)
      ..setState(_permissions(Room(id: _roomId, client: sender)));
    sender.rooms.add(outgoing);
    incoming = Room(id: _roomId, client: recipient)
      ..setState(
        Event.fromJson({
          'type': EventTypes.RoomMember,
          'event_id': r'$reader',
          'sender': recipient.userID,
          'state_key': recipient.userID,
          'content': {'membership': Membership.join, 'displayname': 'Reader'},
        }, Room(id: _roomId, client: recipient)),
      );
  });

  Event received(Map<String, dynamic> content) => Event.fromJson({
    'type': EventTypes.Message,
    'sender': _sender,
    'event_id': r'$sent',
    'content': content,
  }, incoming);

  test(
    'HTTP payload retains room link, personal mentions and reply mention',
    () async {
      final reply = Event.fromJson({
        'type': EventTypes.Message,
        'event_id': r'$reply',
        'sender': '@reply:example.org',
        'content': {'body': 'Hello', 'msgtype': 'm.text'},
      }, outgoing);
      await outgoing.sendTextWithRoomMentions(
        '@room请看 @alice:example.org',
        inReplyTo: reply,
      );
      expect(requestUri.path, contains('/send/m.room.message/'));
      expect(wire['m.mentions'], {
        'room': true,
        'user_ids': ['@alice:example.org', '@reply:example.org'],
      });
      expect(
        wire['formatted_body'],
        contains('href="https://matrix.to/#/$_roomId">@room</a>'),
      );
      expect(wire['m.relates_to'], {
        'm.in_reply_to': {'event_id': r'$reply'},
      });
    },
  );

  test(
    'reproduces lost room notifications before cached permissions are loaded',
    () async {
      final event = received({
        'msgtype': 'm.text',
        'body': '@room ',
        'm.mentions': {'room': true},
      });
      expect(_rules().match(event).notify, isFalse);
      await restoreRoomMentionPowerLevels(incoming);
      expect(_rules().match(event).notify, isTrue);
      expect(_rules().match(event).highlight, isTrue);
      expect(database.saved.single.type, EventTypes.RoomPowerLevels);
      await restoreRoomMentionPowerLevels(incoming);
      expect(database.reads, 1);
    },
  );

  test(
    'both user-reported message formats have the same notification decision',
    () async {
      await restoreRoomMentionPowerLevels(incoming);
      for (final content in [
        {'body': '@room ', 'formatted_body': '@room '},
        {
          'body': _roomId,
          'formatted_body': '<a href="https://matrix.to/#/$_roomId">@room </a>',
        },
      ]) {
        final event = received({
          ...content,
          'msgtype': 'm.text',
          'm.mentions': {'room': true},
        });
        expect(_rules().match(event).notify, isTrue);
        expect(_rules(enabled: false).match(event).notify, isFalse);
        expect(_rules(muted: true).match(event).notify, isFalse);
      }
    },
  );

  test(
    'does not replace newer permissions with stale cached permissions',
    () async {
      incoming.setState(_permissions(incoming, senderLevel: 0));
      await restoreRoomMentionPowerLevels(incoming);
      expect(database.reads, 0);
      expect(
        _rules()
            .match(
              received({
                'm.mentions': {'room': true},
              }),
            )
            .notify,
        isFalse,
      );
    },
  );

  test(
    'upgrade migrates stored permissions before the first room preload',
    () async {
      sqfliteFfiInit();
      final sqlite = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      final store = await MatrixSdkDatabase.init(
        'mention-upgrade',
        database: sqlite,
      );
      addTearDown(store.close);
      final transport = MockClient((_) async => http.Response('{}', 200));
      final oldClient = Client('old-version', database: store);
      final oldRoom = Room(id: _roomId, client: oldClient);
      await store.transaction(() async {
        await store.storeRoomUpdate(
          _roomId,
          JoinedRoomUpdate(),
          null,
          oldClient,
        );
        await store.storeEventUpdate(
          _roomId,
          _permissions(oldRoom),
          EventUpdateType.state,
          oldClient,
        );
      });
      final upgraded = _Client('@reader:example.org', store, transport);
      expect(
        (await store.getRoomList(
          upgraded,
        )).single.getState(EventTypes.RoomPowerLevels),
        isNull,
      );
      await migrateRoomMentionPowerLevels(upgraded);
      final reloaded = (await store.getRoomList(upgraded)).single;
      expect(reloaded.canSendNotification(_sender), isTrue);
      // A second startup can safely use the preloaded event.
      await migrateRoomMentionPowerLevels(upgraded);
      expect(
        (await store.getSingleRoom(
          upgraded,
          _roomId,
        ))!.canSendNotification(_sender),
        isTrue,
      );
    },
  );

  test(
    'actual Megolm encryption preserves mention and room link through HTTP',
    () async {
      await vod.init(
        libraryPath: Platform.environment['MENTION_TEST_VODOZEMAC_DIR'] ?? './',
      );
      final encryption = _Encryption(sender);
      sender.testEncryption = encryption;
      outgoing.setState(
        Event.fromJson({
          'type': EventTypes.Encryption,
          'event_id': r'$encryption',
          'sender': _sender,
          'state_key': '',
          'content': {'algorithm': AlgorithmTypes.megolmV1AesSha2},
        }, outgoing),
      );
      final inbound = vod.InboundGroupSession(
        encryption.sessions.group.sessionKey,
      );
      await outgoing.sendTextWithRoomMentions('@room请看 @alice:example.org');
      expect(requestUri.path, contains('/send/m.room.encrypted/'));
      expect(wire.containsKey('body'), isFalse);
      expect(wire.containsKey('m.mentions'), isFalse);
      final decrypted =
          jsonDecode(inbound.decrypt(wire['ciphertext'] as String).plaintext)
              as Map<String, dynamic>;
      expect(decrypted['room_id'], _roomId);
      final content = decrypted['content'] as Map<String, dynamic>;
      expect(content['m.mentions'], {
        'room': true,
        'user_ids': ['@alice:example.org'],
      });
      expect(
        content['formatted_body'],
        contains('href="https://matrix.to/#/$_roomId">@room</a>'),
      );
      await restoreRoomMentionPowerLevels(incoming);
      expect(_rules().match(received(content)).notify, isTrue);
    },
  );
}
