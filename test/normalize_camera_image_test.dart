// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:fluffychat/utils/normalize_camera_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  for (var orientation = 1; orientation <= 8; orientation++) {
    test('normalizes camera EXIF orientation $orientation before preview', () {
      final source = img.Image(width: 80, height: 40);
      for (var y = 0; y < source.height; y++) {
        for (var x = 0; x < source.width; x++) {
          source.setPixelRgb(x, y, x < 40 ? 240 : 20, y < 20 ? 240 : 20, 20);
        }
      }
      // Inject EXIF after encoding: the JPEG encoder may itself bake orientation.
      final exif = img.ExifData()..imageIfd.orientation = orientation;
      final input = img.injectJpgExif(img.encodeJpg(source), exif)!;
      final expected = img.bakeOrientation(source..exif = exif);
      final output = normalizeCameraImage(input);
      final result = img.decodeJpg(output)!;

      expect(result.width, expected.width);
      expect(result.height, expected.height);
      expect(
        img.decodeJpgExif(output)?.imageIfd.hasOrientation ?? false,
        isFalse,
      );
      for (final x in [10, result.width - 10]) {
        for (final y in [10, result.height - 10]) {
          final actualPixel = result.getPixel(x, y);
          final expectedPixel = expected.getPixel(x, y);
          expect(actualPixel.r, closeTo(expectedPixel.r, 15));
          expect(actualPixel.g, closeTo(expectedPixel.g, 15));
          expect(actualPixel.b, closeTo(expectedPixel.b, 15));
        }
      }
      // A second pass must not rotate or mirror an already normalized photo.
      final again = img.decodeJpg(normalizeCameraImage(output))!;
      expect(again.width, result.width);
      expect(again.height, result.height);
      expect(again.getPixel(10, 10).r, closeTo(result.getPixel(10, 10).r, 15));
      expect(again.getPixel(10, 10).g, closeTo(result.getPixel(10, 10).g, 15));
    });
  }

  test('converts a camera image without EXIF to a valid JPEG', () {
    final source = img.Image(width: 40, height: 80);
    final result = img.decodeJpg(normalizeCameraImage(img.encodePng(source)))!;
    expect(result.width, 40);
    expect(result.height, 80);
  });

  test('rejects empty or invalid camera photos before opening the preview', () {
    expect(() => normalizeCameraImage(Uint8List(0)), throwsFormatException);
    expect(
      () => normalizeCameraImage(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });
}
