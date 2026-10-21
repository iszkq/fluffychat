// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:matrix/matrix.dart';

// Preserve bracketed user mentions and Matrix IDs such as @room:example.org.
final _roomMention = RegExp(
  r'@\[[^\]]*\](?:#\d+)?|@room(?![A-Za-z0-9_:/+-]|\.[A-Za-z0-9])',
);
final _whitespace = RegExp(r'\s');

extension RoomMentionExtension on Room {
  Future<String?> sendTextWithRoomMentions(
    String message, {
    Event? inReplyTo,
    String? editEventId,
    bool parseCommands = true,
    String? threadRootEventId,
  }) {
    final userId = client.userID;
    final allowed = userId != null && canSendNotification(userId);
    final normalized = message.replaceAllMapped(_roomMention, (match) {
      if (match[0]!.startsWith('@[')) return match[0]!;
      // A visible but inert token also avoids legacy body-based notifications.
      if (!allowed) return '@\u200broom';
      // The pinned SDK recognizes @room only when followed by whitespace/end.
      // Add its delimiter for Chinese and punctuation, then let the SDK build
      // all mentions, Markdown, commands, replies, edits and encrypted events.
      if (match.end < message.length &&
          !_whitespace.hasMatch(message[match.end])) {
        return '@room ';
      }
      return '@room';
    });
    return sendTextEvent(
      normalized,
      inReplyTo: inReplyTo,
      editEventId: editEventId,
      parseCommands: parseCommands,
      threadRootEventId: threadRootEventId,
    );
  }
}
