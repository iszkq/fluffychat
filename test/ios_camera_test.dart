// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/ios_camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('im.fluffychat/ios_camera');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'requests app language and returns a JPEG file from native camera',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'capturePhoto');
        expect(call.arguments, {'languageCode': 'zh-Hans'});
        return '/tmp/camera-landscape.jpg';
      });
      final photo = await IosCamera.capturePhoto('zh-Hans');
      expect(photo!.path, '/tmp/camera-landscape.jpg');
      expect(photo.mimeType, 'image/jpeg');
      expect(photo.name, 'camera-landscape.jpg');
    },
  );

  test('cancelling native camera does not create a photo', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await IosCamera.capturePhoto('zh'), isNull);
  });

  test('native camera failures reach the preview error handler', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'camera_capture_failed',
        message: '无法拍照，请重试',
      );
    });
    await expectLater(
      IosCamera.capturePhoto('zh'),
      throwsA(isA<PlatformException>()),
    );
  });

  test(
    'rejects an empty native path instead of opening a blank preview',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => '');
      await expectLater(IosCamera.capturePhoto('zh'), throwsFormatException);
    },
  );
}
