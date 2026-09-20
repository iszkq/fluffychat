// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/setting_keys.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses saved Android background notification modes', () {
    expect(
      AndroidBackgroundNotificationsMode.fromSetting('persistent'),
      AndroidBackgroundNotificationsMode.persistent,
    );
    expect(
      AndroidBackgroundNotificationsMode.fromSetting('whileAppRunning'),
      AndroidBackgroundNotificationsMode.whileAppRunning,
    );
  });

  test('falls back to persistent mode for unknown saved values', () {
    expect(
      AndroidBackgroundNotificationsMode.fromSetting('unknown'),
      AndroidBackgroundNotificationsMode.persistent,
    );
  });
}
