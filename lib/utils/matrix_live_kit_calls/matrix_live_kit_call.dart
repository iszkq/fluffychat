// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/matrix_live_kit_calls/call_keys_event_content.dart';
import 'package:fluffychat/utils/matrix_live_kit_calls/matrix_live_kit_call_member.dart';
import 'package:matrix/matrix.dart';

bool _isLiveKitUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      const {'https', 'http'}.contains(uri.scheme) &&
      uri.host.isNotEmpty;
}

extension MatrixRtcClientExtension on Client {
  Future<List<String>> getLiveKitServiceUrls() async {
    try {
      final response = await request(
        .GET,
        '/client/unstable/org.matrix.msc4143/rtc/transports',
      ).timeout(const Duration(seconds: 10));
      final transports = response['transports'];
      if (transports is List) {
        final urls = transports
            .whereType<Map>()
            .where((transport) => transport['type'] == 'm.livekit')
            .map((transport) => transport['url'])
            .whereType<String>()
            .where(_isLiveKitUrl)
            .toSet()
            .toList();
        if (urls.isNotEmpty) return urls;
      }
    } catch (error) {
      Logs().d('RTC transports unavailable; trying well-known', error);
    }
    try {
      final wellKnown = await getWellknown();
      final foci =
          wellKnown.additionalProperties['org.matrix.msc4143.rtc_foci'];
      final entries = foci is Map
          ? [foci]
          : foci is List
          ? foci
          : const [];
      final urls = entries
          .whereType<Map>()
          .map((focus) => focus['livekit_service_url'])
          .whereType<String>()
          .where(_isLiveKitUrl)
          .toSet()
          .toList();
      if (urls.isNotEmpty) return urls;
    } catch (error) {
      Logs().d('RTC well-known unavailable; trying configured fallback', error);
    }
    final fallback = AppSettings.fallbackLiveKitInstance.value.trim();
    return [if (_isLiveKitUrl(fallback)) fallback];
  }

  Stream<CallKeysEvent> get onCallEncryptionKeys => onToDeviceEvent.stream
      .where((event) => event.type == CallKeysEventContent.eventType)
      .map(CallKeysEvent.fromToDeviceEvent);
}

extension MatrixRtcRoomExtension on Room {
  bool get hasActiveMatrixRtcCall => getActiveMatrixRtcMembers().isNotEmpty;

  MatrixRtcCallIntent? get activeMatrixRtcCallIntent {
    final members = getActiveMatrixRtcMembers();
    if (members.isEmpty) return null;
    if (members.any((member) => member.callIntent == .video)) return .video;
    return .voice;
  }

  bool get hasPermissionForMatrixRtcCall =>
      canChangeStateEvent(MatrixRtcCallMember.eventType);

  List<MatrixRtcCallMember> getActiveMatrixRtcMembers() {
    final states = this.states[MatrixRtcCallMember.eventType];
    if (states == null) return [];
    // Empty content {} means the member has left — filter those out
    final activeMemberStates = states.values.where((event) {
      if (event.content.isEmpty) return false;
      if (event is! Event) return false;
      try {
        final validContent = MatrixRtcCallMember.fromJson(
          event.content,
          senderId: event.senderId,
        );
        if (validContent.focusActive?.type != 'livekit') return false;
        final expiresAt = (validContent.createdAt ?? event.originServerTs).add(
          validContent.expires,
        );
        if (expiresAt.isBefore(DateTime.now())) return false;
        return true;
      } catch (e, s) {
        Logs().d('Invalid "org.matrix.msc3401.call.member" event!', e, s);
        return false;
      }
    });
    return activeMemberStates
        .map(
          (state) => MatrixRtcCallMember.fromJson(
            state.content,
            senderId: state.senderId,
          ),
        )
        .toList();
  }

  String get _ownMatrixRtcMembershipStateKey =>
      '_${client.userID}_${client.deviceID}_m.call';

  MatrixRtcCallMember? get ownMatrixRtcMembership {
    final state = getState(
      MatrixRtcCallMember.eventType,
      _ownMatrixRtcMembershipStateKey,
    );
    if (state == null || state.content.isEmpty) return null;
    try {
      return MatrixRtcCallMember.fromJson(
        state.content,
        senderId: state.senderId,
      );
    } catch (e, s) {
      Logs().d(
        'Unknown format for ${MatrixRtcCallMember.eventType} event',
        e,
        s,
      );
      return null;
    }
  }

  Future<void> setMatrixRtcMembershipState(
    List<MatrixRtcFocusPreferred> fociPreferred, {
    MatrixRtcCallIntent intent = MatrixRtcCallIntent.video,
  }) => client.setRoomStateWithKey(
    id,
    MatrixRtcCallMember.eventType,
    _ownMatrixRtcMembershipStateKey,
    MatrixRtcCallMember(
      application: 'm.call',
      callId: '',
      deviceId: client.deviceID,
      expires: Duration(hours: 4),
      createdAt: DateTime.now(),
      fociPreferred: fociPreferred,
      focusActive: MatrixRtcFocusActive(
        focusSelection: 'oldest_membership',
        type: 'livekit',
      ),
      callIntent: intent,
      membershipId: '${client.userID}:${client.deviceID}',
      scope: 'm.room',
      senderId: null,
    ).toJson(),
  );

  bool participantRaisedHandInMatrixRtcCall(
    String matrixId,
    Timeline timeline,
  ) {
    final stateEvent =
        states[MatrixRtcCallMember.eventType]?[_ownMatrixRtcMembershipStateKey]
            as Event?;
    if (stateEvent == null) return false;
    final aggregatedEvents = timeline
        .aggregatedEvents[stateEvent.eventId]?['m.annotation']
        ?.where(
          (event) =>
              event.senderId == matrixId &&
              event.content
                      .tryGetMap<String, Object?>('m.relates_to')
                      ?.tryGet<String>('key') ==
                  '🖐️',
        );
    if (aggregatedEvents == null || aggregatedEvents.isEmpty) return false;

    return true;
  }

  Future<String?> raiseHandInMatrixRtcCall() async {
    final ownMemberStateEvent =
        states[MatrixRtcCallMember.eventType]?[_ownMatrixRtcMembershipStateKey]
            as Event?;
    if (ownMemberStateEvent == null) return null;
    return await sendReaction(ownMemberStateEvent.eventId, '🖐️');
  }

  Future<String?> lowerHandInMatrixRtcCall(Timeline timeline) async {
    final ownMemberStateEvent =
        states[MatrixRtcCallMember.eventType]?[_ownMatrixRtcMembershipStateKey]
            as Event?;
    if (ownMemberStateEvent == null) return null;
    final reaction = timeline.events.firstWhereOrNull(
      (event) =>
          event.type == EventTypes.Reaction &&
          event.relationshipEventId == ownMemberStateEvent.eventId &&
          event.senderId == client.userID &&
          event.status.isSent &&
          event.content
                  .tryGetMap<String, Object?>('m.relates_to')
                  ?.tryGet<String>('key') ==
              '🖐️',
    );
    if (reaction == null) {
      throw Exception('Hand raise reaction event not found!');
    }
    return await reaction.redactEvent();
  }

  Future<void> shareMatrixRtcCallKey({
    required Uint8List key,
    required int index,
    required String memberId,
    required List<DeviceKeys> deviceKeys,
  }) async {
    if (deviceKeys.isEmpty) {
      Logs().d('No devices to share call keys with');
      return;
    }
    Logs().d(
      'Share call keys with',
      deviceKeys.map((key) => '${key.userId}:${key.deviceId}'),
    );

    final doNotEncryptTo = deviceKeys.where((d) => !d.encryptToDevice);
    if (doNotEncryptTo.isNotEmpty) {
      Logs().w(
        'Not sharing keys with ${doNotEncryptTo.length} device(s) because of key sharing restrictions!',
      );
      deviceKeys.removeWhere((d) => !d.encryptToDevice);
    }

    await client.sendToDeviceEncrypted(
      deviceKeys,
      CallKeysEventContent.eventType,
      CallKeysEventContent(
        keys: CallKeysEntry(index: index, key: base64Encode(key)),
        member: CallKeysMember(id: memberId, claimedDeviceId: client.deviceID!),
        roomId: id,
        sentTs: DateTime.now().millisecondsSinceEpoch,
        session: CallKeysSession(
          application: 'm.call',
          callId: '',
          scope: 'm.room',
        ),
      ).toJson(),
    );
  }

  Future<MatrixRtcCredentials> joinMatrixRtcCall({
    MatrixRtcCallIntent intent = MatrixRtcCallIntent.video,
    List<String>? urls,
  }) async {
    await postLoad();
    if (ownMatrixRtcMembership != null) {
      Logs().w(
        'User has already an active rtc membership state in this room. Resetting it now...',
      );
    }
    Logs().d('[Join MatrixRtc Call] (1/5) Get LiveKit Backend Urls...');

    final hasActiveMatrixRtcCall = this.hasActiveMatrixRtcCall;

    urls ??= getActiveMatrixRtcMembers()
        .map(
          (state) =>
              state.fociPreferred.map((focus) => focus.livekitServiceUrl),
        )
        .fold<List<String>>([], (urls, foci) => [...urls, ...foci]);

    if (urls.isEmpty) {
      urls.addAll(await client.getLiveKitServiceUrls());
    }

    Logs().v('Available SFUs', urls);
    if (urls.isEmpty) {
      throw Exception('This server does not support livekit calls!');
    }

    Logs().d(
      '[Join MatrixRtc Call] (2/5) Set "${MatrixRtcCallMember.eventType}" State event...',
    );
    await setMatrixRtcMembershipState(
      urls
          .map(
            (url) => MatrixRtcFocusPreferred(
              type: 'livekit',
              livekitServiceUrl: url,
              livekitAlias: id,
            ),
          )
          .toList(),
      intent: intent,
    );

    if (!hasActiveMatrixRtcCall) {
      final dmUserId = directChatMatrixID;
      if (dmUserId != null) {
        await sendRtcNotification(type: .ring, userIds: [dmUserId]);
      } else {
        await sendRtcNotification(type: .notification, mentionRoom: true);
      }
    }

    Logs().v('[Join MatrixRtc Call] (3/5) Request OpenId Token...');
    final openIdCredentials = await client.requestOpenIdToken(
      client.userID!,
      {},
    );

    for (final url in urls) {
      try {
        Logs().d(
          '[Join MatrixRtc Call] (4/5) Try authenticate to LiveKit instance $url...',
        );
        final response = await client.httpClient.post(
          Uri.parse('${url.replaceAll(RegExp(r'/+$'), '')}/sfu/get'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'room': id,
            'openid_token': openIdCredentials.toJson(),
            'device_id': client.deviceID,
          }),
        );
        if (response.statusCode != 200) {
          throw Exception(response.reasonPhrase ?? response.body);
        }
        final json =
            jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, Object?>;
        Logs().d('Use SFU', url);
        return MatrixRtcCredentials.fromJson(json);
      } catch (e) {
        Logs().v(
          '[Join MatrixRtc Call] (4/4) Unable to authenticate to $url',
          e,
        );
      }
    }
    throw Exception(
      'Unable to authenticate to any of the visible LiveKit instances!\nSFU list: $urls\nActive Call: $hasActiveMatrixRtcCall',
    );
  }

  Future<void> leaveMatrixRtcCall() async {
    await client.setRoomStateWithKey(
      id,
      MatrixRtcCallMember.eventType,
      _ownMatrixRtcMembershipStateKey,
      {},
    );
  }
}

class MatrixRtcCredentials {
  final String url, jwt;
  const MatrixRtcCredentials({required this.url, required this.jwt});
  factory MatrixRtcCredentials.fromJson(Map<String, Object?> json) =>
      MatrixRtcCredentials(
        url: json['url'] as String,
        jwt: json['jwt'] as String,
      );
}

enum MatrixRtcCallIntent {
  voice(callKitType: 0),
  video(callKitType: 1);

  final int callKitType;
  const MatrixRtcCallIntent({required this.callKitType});
}
