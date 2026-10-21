// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/deep_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('room notification preserves the account and target event', () {
    final route = Uri.parse(
      routeForDeepLink(
        Uri.parse(
          'im.fluffychat://room/%21room%3Aexample.org?client=Bob&event=%24message',
        ),
      )!,
    );
    expect(route.pathSegments, ['rooms', '!room:example.org']);
    expect(route.queryParameters, {'client': 'Bob', 'event': r'$message'});
  });

  test('matrix links keep repeated via servers and event IDs', () {
    for (final link in [
      'matrix:u/alice:example.org',
      'matrix:r/general:example.org?via=a.example&via=b.example',
      'matrix:roomid/room:example.org/e/message?via=a.example',
    ]) {
      final route = Uri.parse(routeForDeepLink(Uri.parse(link))!);
      expect(route.path, '/rooms/newprivatechat');
      expect(route.fragment, link);
    }
  });

  test('custom invite link preserves account selection', () {
    final route = Uri.parse(
      routeForDeepLink(
        Uri.parse('im.fluffychat://chat/%23general%3Aexample.org?client=Alice'),
      )!,
    );
    expect(route.queryParameters['client'], 'Alice');
    expect(route.fragment, contains('%23general'));
  });

  test('malformed external links do not index missing path segments', () {
    for (final link in [
      'matrix:',
      'matrix:u',
      'im.fluffychat://room',
      'im.fluffychat://room/not-a-room',
      'im.fluffychat://room/%21room%3Aexample.org/extra',
    ]) {
      expect(routeForDeepLink(Uri.parse(link)), '/rooms', reason: link);
    }
    expect(routeForDeepLink(Uri.parse('https://example.org')), isNull);
  });
}
