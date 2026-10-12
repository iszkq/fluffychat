// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Converts a camera photo to a JPEG whose pixels already have the intended
/// orientation. Run in an isolate, before both previewing and sending the photo.
Uint8List normalizeCameraImage(Uint8List bytes) {
  if (bytes.length < 8) {
    throw const FormatException('Camera photo is empty or truncated');
  }
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('Unable to decode camera photo');
  }

  // JPEG decoding already applies EXIF orientation; bakeOrientation also covers
  // other camera formats without rotating an already oriented JPEG a second time.
  final oriented = img.bakeOrientation(decoded);
  // Do not copy the camera's orientation, embedded thumbnail or stale dimensions
  // back into the new JPEG. The preview and upload must use the same pixels.
  oriented.exif = img.ExifData();
  return img.encodeJpg(oriented, quality: 100);
}
