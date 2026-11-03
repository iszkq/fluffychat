// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

/// The MSC4108 v2 format used by matrix-js-sdk's signInByGeneratingQR.
/// Verification QR codes (MATRIX v2 modes 0..2) are a different protocol.
class QrLoginPayload {
  final Uint8List publicKey;
  final Uri rendezvous;
  final bool passwordLogin;

  QrLoginPayload._(this.publicKey, this.rendezvous, this.passwordLogin);

  static bool _hasHeader(List<int> bytes) =>
      bytes.length >= 6 &&
      List.generate(
        6,
        (i) => bytes[i] == 'MATRIX'.codeUnitAt(i),
      ).every((v) => v);

  /// Scanner rawBytes are usually QR *codewords*, not decoded payload bytes.
  /// Prefer those over text: binary Curve25519 keys aren't UTF-8 strings.
  static QrLoginPayload? fromScan({String? text, List<int>? rawBytes}) {
    final candidates = <List<int>>[];
    if (rawBytes != null) {
      candidates.add(rawBytes);
      for (final countBits in [8, 16]) {
        final bytes = _readByteSegments(rawBytes, countBits);
        if (bytes != null) candidates.add(bytes);
      }
    }
    // Only use text if its bytes are losslessly representable as Latin-1.
    if (text != null && text.codeUnits.every((unit) => unit <= 255)) {
      candidates.add(text.codeUnits);
    }
    for (final bytes in candidates) {
      if (!_hasHeader(bytes) || bytes.length < 8) continue;
      if (bytes[6] == 2 && bytes[7] <= 2) continue;
      return fromBytes(bytes);
    }
    return null;
  }

  static QrLoginPayload fromBytes(List<int> bytes) {
    if (!_hasHeader(bytes) || bytes.length < 42 || bytes[6] != 2) {
      throw const FormatException('Unsupported login QR version');
    }
    // Mode 4 is mxchat's app-to-app password handoff, not MSC4108 OAuth.
    if (bytes[7] != 3 && bytes[7] != 4) {
      throw const FormatException('Scan a QR displayed by the new device');
    }
    final length = (bytes[40] << 8) | bytes[41];
    if (length == 0 || bytes.length != 42 + length) {
      throw const FormatException('Invalid login QR length');
    }
    final uri = Uri.tryParse(utf8.decode(bytes.sublist(42)));
    if (uri == null || !isSecureQrLoginUri(uri)) {
      throw const FormatException('Login QR requires an HTTPS rendezvous');
    }
    return QrLoginPayload._(
      Uint8List.fromList(bytes.sublist(8, 40)),
      uri,
      bytes[7] == 4,
    );
  }

  static List<int>? _readByteSegments(List<int> words, int countBits) {
    var offset = 0;
    int read(int length) {
      if (offset + length > words.length * 8) throw const FormatException();
      var value = 0;
      for (var i = 0; i < length; i++, offset++) {
        value = (value << 1) | ((words[offset ~/ 8] >> (7 - offset % 8)) & 1);
      }
      return value;
    }

    final bytes = <int>[];
    try {
      while (offset + 4 <= words.length * 8) {
        final mode = read(4);
        if (mode == 0) break;
        if (mode == 7) {
          final first = read(8);
          if ((first & 0x80) == 0) continue;
          if ((first & 0xc0) == 0x80) {
            read(8);
          } else if ((first & 0xe0) == 0xc0) {
            read(16);
          } else {
            return null;
          }
          continue;
        }
        if (mode != 4) return null;
        final count = read(countBits);
        if (count > 8192) return null;
        for (var i = 0; i < count; i++) {
          bytes.add(read(8));
        }
      }
      return bytes.isEmpty ? null : bytes;
    } on FormatException {
      return null;
    }
  }
}

bool isSecureQrLoginUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty &&
    !uri.hasFragment;
