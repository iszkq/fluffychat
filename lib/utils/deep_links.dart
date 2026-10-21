// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:matrix/matrix.dart';

/// Routes external links without losing event, via or account information.
String? routeForDeepLink(Uri uri) {
  try {
    if (uri.scheme == 'matrix') {
      final identifier = uri.toString().parseIdentifierIntoParts();
      if (identifier == null) return '/rooms';
      // The existing Matrix link flow resolves aliases, asks before joining
      // unknown rooms and understands event IDs and repeated via parameters.
      return Uri(
        path: '/rooms/newprivatechat',
        fragment: uri.toString(),
        queryParameters: _accountParameters(uri),
      ).toString();
    }
    if (uri.scheme != 'im.fluffychat') return null;
    if (uri.host == 'chat') {
      if (uri.pathSegments.isEmpty) return '/rooms';
      return Uri(
        path: '/rooms/newprivatechat',
        fragment: uri.toString(),
        queryParameters: _accountParameters(uri),
      ).toString();
    }
    if (uri.host != 'room' || uri.pathSegments.length != 1) return '/rooms';
    final roomId = uri.pathSegments.single;
    if (!roomId.isValidMatrixIdStrict() || !roomId.startsWith('!')) {
      return '/rooms';
    }
    return Uri(
      pathSegments: ['', 'rooms', roomId],
      queryParameters: {
        ..._accountParameters(uri),
        if (uri.queryParameters['event'] case final String eventId
            when eventId.startsWith(r'$'))
          'event': eventId,
        if (uri.queryParameters['action'] == 'call') 'action': 'call',
      },
    ).toString();
  } on FormatException {
    return '/rooms';
  }
}

Map<String, String> _accountParameters(Uri uri) => {
  if (uri.queryParameters['client'] case final String client
      when client.isNotEmpty)
    'client': client,
};
