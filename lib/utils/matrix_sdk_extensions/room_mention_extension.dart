// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
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
    // Only text-producing SDK commands use the formatting adapter. Other
    // commands must operate on the actual room, including its live state.
    final useComposer =
        !parseCommands ||
        !normalized.startsWith('/') ||
        normalized.startsWith('//') ||
        RegExp(
          r'^/(send|me|plain)(?: |$)',
          caseSensitive: false,
        ).hasMatch(normalized);
    final target = useComposer ? _RoomMentionComposer(this) : this;
    return target.sendTextEvent(
      normalized,
      inReplyTo: inReplyTo,
      editEventId: editEventId,
      parseCommands: parseCommands,
      threadRootEventId: threadRootEventId,
    );
  }
}

/// Lets the SDK compose mentions, Markdown and commands, then adds the room
/// link before the real room handles replies, edits, queuing and encryption.
class _RoomMentionComposer extends Room {
  final Room target;

  _RoomMentionComposer(this.target)
    : super(
        id: target.id,
        client: target.client,
        roomAccountData: target.roomAccountData,
      ) {
    states = target.states;
  }

  @override
  String? getMention(String mention) => target.getMention(mention);

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
  }) {
    if (content.tryGetMap<String, Object?>('m.mentions')?['room'] == true) {
      final html =
          content.tryGet<String>('formatted_body') ??
          htmlEscape
              .convert(content.tryGet<String>('body') ?? '')
              .replaceAll('\n', '<br>');
      final fragment = html_parser.parseFragment(html);
      var changed = false;
      void addLinks(dom.Node node) {
        if (node is dom.Element &&
            {
              'a',
              'code',
              'pre',
              'blockquote',
              'mx-reply',
            }.contains(node.localName)) {
          return;
        }
        if (node is dom.Text) {
          final matches = _roomMention
              .allMatches(node.data)
              .where((match) => match[0] == '@room')
              .toList();
          if (matches.isEmpty) return;
          final parent = node.parentNode!;
          var start = 0;
          for (final match in matches) {
            parent.insertBefore(
              dom.Text(node.data.substring(start, match.start)),
              node,
            );
            final link = dom.Element.tag('a')
              ..attributes['href'] = 'https://matrix.to/#/$id'
              ..text = '@room';
            parent.insertBefore(link, node);
            start = match.end;
          }
          parent.insertBefore(dom.Text(node.data.substring(start)), node);
          node.remove();
          changed = true;
          return;
        }
        for (final child in node.nodes.toList()) {
          addLinks(child);
        }
      }

      addLinks(fragment);
      if (changed) {
        content['format'] = 'org.matrix.custom.html';
        content['formatted_body'] = fragment.outerHtml;
      }
    }
    return target.sendEvent(
      content,
      type: type,
      txid: txid,
      inReplyTo: inReplyTo,
      editEventId: editEventId,
      threadRootEventId: threadRootEventId,
      threadLastEventId: threadLastEventId,
      displayPendingEvent: displayPendingEvent,
    );
  }
}
