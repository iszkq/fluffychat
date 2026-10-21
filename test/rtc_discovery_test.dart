// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/matrix_live_kit_calls/matrix_live_kit_call.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Client implements Client {
  Map<String, Object?> transports = {};
  Object? foci;
  bool offline = false;
  int wellKnownRequests = 0;

  @override
  Future<Map<String, Object?>> request(
    RequestType type,
    String action, {
    dynamic data = '',
    String contentType = 'application/json',
    Map<String, Object?>? query,
  }) async {
    expect(type, RequestType.GET);
    // MatrixApi adds /_matrix itself.
    expect(action, '/client/unstable/org.matrix.msc4143/rtc/transports');
    if (offline) throw StateError('unsupported');
    return transports;
  }

  @override
  Future<DiscoveryInformation> getWellknown({
    Duration cacheLifetime = const Duration(days: 3),
    bool throwOnUpdateFailure = false,
  }) async {
    wellKnownRequests++;
    return DiscoveryInformation.fromJson({
      'm.homeserver': {'base_url': 'https://example.org'},
      'org.matrix.msc4143.rtc_foci': foci,
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    await AppSettings.fallbackLiveKitInstance.setItem(
      'https://fallback.example',
    );
  });

  test(
    'prefers transports, filters invalid URLs and removes duplicates',
    () async {
      final client = _Client()
        ..transports = {
          'transports': [
            {'type': 'm.livekit', 'url': 'https://rtc.example'},
            {'type': 'm.livekit', 'url': 'https://rtc.example'},
            {'type': 'm.livekit', 'url': 'javascript:invalid'},
            {'type': 'other', 'url': 'https://other.example'},
          ],
        };
      expect(await client.getLiveKitServiceUrls(), ['https://rtc.example']);
      expect(client.wellKnownRequests, 0);
    },
  );

  test('falls back to both historical well-known shapes', () async {
    for (final foci in [
      {'livekit_service_url': 'https://legacy.example'},
      [
        {'livekit_service_url': 'https://legacy.example'},
      ],
    ]) {
      final client = _Client()
        ..offline = true
        ..foci = foci;
      expect(await client.getLiveKitServiceUrls(), ['https://legacy.example']);
    }
  });

  test('uses configured fallback when discovery has no usable URL', () async {
    expect(await _Client().getLiveKitServiceUrls(), [
      'https://fallback.example',
    ]);
  });
}
