// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/utils/client_manager.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reset restores settings without removing accounts or drafts', () async {
    SharedPreferences.setMockInitialValues({
      ClientManager.clientNamespace: ['alice', 'bob'],
      'draft_!room:example.org': 'Unsent message',
      AppSettings.fontSizeFactor.key: 1.5,
      AppSettings.voiceTranscriptionEndpoint.key: 'https://example.org/api',
    });
    await AppSettings.init(loadWebConfigFile: false);
    await AppSettings.reset(loadWebConfigFile: false);
    expect(AppSettings.fontSizeFactor.value, 1.0);
    expect(AppSettings.sendOnEnter.value, !PlatformInfos.isMobile);
    expect(AppSettings.doubleTapToReact.value, PlatformInfos.isMobile);
    expect(AppSettings.store.getStringList(ClientManager.clientNamespace), [
      'alice',
      'bob',
    ]);
    expect(
      AppSettings.store.getString('draft_!room:example.org'),
      'Unsent message',
    );
  });
}
