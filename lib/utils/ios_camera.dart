// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:cross_file/cross_file.dart';
import 'package:flutter/services.dart';

/// Uses AVFoundation and app-owned confirmation controls on iOS. The native
/// result completes only after dismissal, with orientation baked into the JPEG.
class IosCamera {
  static const _channel = MethodChannel('im.fluffychat/ios_camera');

  static Future<XFile?> capturePhoto(String languageCode) async {
    final path = await _channel.invokeMethod<String>('capturePhoto', {
      'languageCode': languageCode,
    });
    if (path == null) return null;
    if (path.isEmpty) {
      throw const FormatException('Camera returned an empty photo path');
    }
    return XFile(path, mimeType: 'image/jpeg');
  }
}
