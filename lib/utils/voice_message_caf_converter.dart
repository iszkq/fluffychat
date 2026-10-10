// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

/// Repackages OGG/Opus for Apple's audio player without changing the audio.
///
/// OGG's input rate is informational: granules and pre-skip always use 48 kHz.
/// CAF packet sizes must use variable-length integers, not single bytes.
Uint8List convertOggOpusToCaf(Uint8List bytes) {
  final packets = <Uint8List>[];
  var pending = BytesBuilder(copy: false);
  int? serial;
  var sequence = 0;
  int? finalGranule;
  var offset = 0;
  while (offset < bytes.length) {
    if (offset + 27 > bytes.length ||
        !_matches(bytes, offset, 'OggS') ||
        bytes[offset + 4] != 0) {
      throw const FormatException('Invalid OGG page header');
    }
    final data = ByteData.sublistView(bytes, offset);
    final flags = bytes[offset + 5];
    final pageSerial = data.getUint32(14, Endian.little);
    if (finalGranule != null ||
        (serial != null && pageSerial != serial) ||
        data.getUint32(18, Endian.little) != sequence++ ||
        (offset == 0 && (flags & 2) == 0) ||
        ((flags & 1) != 0) != (pending.length > 0)) {
      throw const FormatException('Invalid or chained OGG stream');
    }
    serial = pageSerial;
    final segments = bytes[offset + 26];
    final tableStart = offset + 27;
    var bodyOffset = tableStart + segments;
    if (bodyOffset > bytes.length) {
      throw const FormatException('Truncated OGG segment table');
    }
    for (var index = 0; index < segments; index++) {
      final size = bytes[tableStart + index];
      if (bodyOffset + size > bytes.length) {
        throw const FormatException('Truncated OGG audio packet');
      }
      pending.add(Uint8List.sublistView(bytes, bodyOffset, bodyOffset + size));
      bodyOffset += size;
      if (size < 255) {
        packets.add(pending.takeBytes());
        pending = BytesBuilder(copy: false);
      }
    }
    if ((flags & 4) != 0) {
      finalGranule = data.getInt64(6, Endian.little);
    }
    offset = bodyOffset;
  }
  if (pending.length != 0 || finalGranule == null || packets.length < 3) {
    throw const FormatException('Incomplete OGG/Opus stream');
  }
  final head = packets[0];
  if (head.length != 19 ||
      !_matches(head, 0, 'OpusHead') ||
      head[8] != 1 ||
      head[9] < 1 ||
      head[9] > 2 ||
      head[18] != 0 ||
      !_matches(packets[1], 0, 'OpusTags')) {
    throw const FormatException('Unsupported OGG/Opus headers');
  }
  final headData = ByteData.sublistView(head);
  if (headData.getInt16(16, Endian.little) != 0) {
    throw const FormatException('Opus output gain requires decoding');
  }
  final preSkip = headData.getUint16(10, Endian.little);
  final audioPackets = packets.sublist(2);
  final frameCounts = audioPackets.map(_packetSamples).toList();
  final totalFrames = frameCounts.fold<int>(0, (sum, count) => sum + count);
  // Some older senders add pre-skip to the final granule. Clamp that value to
  // the available decoded samples instead of writing an impossible CAF table.
  final endFrame = finalGranule.clamp(0, totalFrames);
  if (endFrame <= preSkip) {
    throw const FormatException('OGG contains no playable Opus frames');
  }
  final fixedFrames = frameCounts.every((count) => count == frameCounts.first)
      ? frameCounts.first
      : 0;

  final description = ByteData(32)
    ..setFloat64(0, 48000, Endian.big)
    ..setUint32(20, fixedFrames, Endian.big)
    ..setUint32(24, head[9], Endian.big);
  description.buffer.asUint8List().setRange(8, 12, ascii.encode('opus'));
  final layout = ByteData(12)
    ..setUint32(0, head[9] == 1 ? 0x00640001 : 0x00650002, Endian.big);
  final tableHeader = ByteData(24)
    ..setInt64(0, audioPackets.length, Endian.big)
    ..setInt64(8, endFrame - preSkip, Endian.big)
    ..setInt32(16, preSkip, Endian.big)
    ..setInt32(20, totalFrames - endFrame, Endian.big);
  final table = BytesBuilder(copy: false)
    ..add(tableHeader.buffer.asUint8List());
  final audio = BytesBuilder(copy: false)..add(Uint8List(4)); // Edit count.
  for (var index = 0; index < audioPackets.length; index++) {
    table.add(_varint(audioPackets[index].length));
    audio.add(audioPackets[index]);
  }
  final output = BytesBuilder(copy: false)
    ..add(const [0x63, 0x61, 0x66, 0x66, 0, 1, 0, 0]);
  void chunk(String type, Uint8List contents) {
    final header = ByteData(12)..setInt64(4, contents.length, Endian.big);
    header.buffer.asUint8List().setRange(0, 4, ascii.encode(type));
    output
      ..add(header.buffer.asUint8List())
      ..add(contents);
  }

  chunk('desc', description.buffer.asUint8List());
  chunk('chan', layout.buffer.asUint8List());
  chunk('data', audio.takeBytes());
  chunk('pakt', table.takeBytes());
  return output.takeBytes();
}

bool _matches(Uint8List bytes, int offset, String signature) {
  if (offset + signature.length > bytes.length) return false;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[offset + index] != signature.codeUnitAt(index)) return false;
  }
  return true;
}

Uint8List _varint(int value) {
  final result = <int>[value & 0x7f];
  while ((value >>= 7) > 0) {
    result.insert(0, (value & 0x7f) | 0x80);
  }
  return Uint8List.fromList(result);
}

int _packetSamples(Uint8List packet) {
  if (packet.isEmpty) throw const FormatException('Empty Opus packet');
  final config = packet[0] >> 3;
  final samplesPerFrame = config >= 16
      ? 120 << (config & 3)
      : config >= 12
      ? 480 << (config & 1)
      : (config & 3) == 3
      ? 2880
      : 480 << (config & 3);
  final frames = switch (packet[0] & 3) {
    0 => 1,
    1 || 2 => 2,
    3 when packet.length > 1 => packet[1] & 0x3f,
    _ => throw const FormatException('Invalid Opus packet'),
  };
  final samples = samplesPerFrame * frames;
  if (samples <= 0 || samples > 5760) {
    throw const FormatException('Invalid Opus packet duration');
  }
  return samples;
}
