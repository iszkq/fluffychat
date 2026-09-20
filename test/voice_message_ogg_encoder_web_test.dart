// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

@TestOn('browser')
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fluffychat/utils/voice_message_ogg_converter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('encodes browser PCM WAV as OGG Opus', () async {
    final ogg = await normalizeVoiceMessageToOgg(_createTestWav());

    expect(ascii.decode(ogg.sublist(0, 4)), 'OggS');
    expect(_containsAscii(ogg, 'OpusHead'), isTrue);
    expect(_containsAscii(ogg, 'OpusTags'), isTrue);
  });
}

Uint8List _createTestWav() {
  const sampleRate = 48000;
  const sampleCount = 4800;
  const headerLength = 44;
  final bytes = Uint8List(headerLength + sampleCount * 2);
  final data = ByteData.sublistView(bytes);

  void writeAscii(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, ascii.encode(value));

  writeAscii(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  data.setUint32(40, sampleCount * 2, Endian.little);
  for (var index = 0; index < sampleCount; index++) {
    final sample = (sin(2 * pi * 440 * index / sampleRate) * 12000).round();
    data.setInt16(headerLength + index * 2, sample, Endian.little);
  }
  return bytes;
}

bool _containsAscii(Uint8List bytes, String value) {
  final signature = ascii.encode(value);
  for (var start = 0; start <= bytes.length - signature.length; start++) {
    var matches = true;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[start + index] != signature[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}
