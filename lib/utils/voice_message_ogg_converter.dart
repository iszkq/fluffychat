// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fluffychat/utils/voice_message_ogg_encoder.dart';

/// Converts supported voice recordings into an OGG/Opus stream.
///
/// Web PCM/WAV is encoded with the bundled WebAssembly codec. Existing WebM
/// and Apple CAF Opus recordings are repackaged without re-encoding. Matrix
/// clients such as Element X expect actual OGG/Opus data, so merely changing
/// the extension is not sufficient.
Future<Uint8List> normalizeVoiceMessageToOgg(Uint8List bytes) async {
  if (_startsWith(bytes, const [0x4f, 0x67, 0x67, 0x53])) return bytes;
  if (_startsWith(bytes, const [0x52, 0x49, 0x46, 0x46]) &&
      _startsWith(bytes, const [0x57, 0x41, 0x56, 0x45], 8)) {
    return encodeWavVoiceMessageToOgg(bytes);
  }
  if (_startsWith(bytes, const [0x1a, 0x45, 0xdf, 0xa3])) {
    return _WebmOpusReader(bytes).convert();
  }
  if (_startsWith(bytes, const [0x63, 0x61, 0x66, 0x66])) {
    return _CafOpusReader(bytes).convert();
  }
  throw const FormatException(
    'The recording is not OGG, WebM/Opus or CAF/Opus',
  );
}

/// Packages already-encoded Opus packets into an OGG stream.
///
/// This is public so the WebAssembly encoder can share the same tested OGG
/// writer as the WebM and CAF repackaging paths.
Uint8List packageOpusPacketsAsOgg({
  required List<Uint8List> packets,
  required int channels,
  required int inputSampleRate,
  required int validSamplesPerChannel,
  int preSkip = 312,
}) => _OpusStream(
  head: _createOpusHead(channels, preSkip, inputSampleRate),
  packets: packets,
  finalGranulePosition: preSkip + validSamplesPerChannel,
).toOgg();

bool _startsWith(Uint8List bytes, List<int> signature, [int offset = 0]) {
  if (bytes.length < offset + signature.length) return false;
  for (var index = 0; index < signature.length; index++) {
    if (bytes[offset + index] != signature[index]) return false;
  }
  return true;
}

class _OpusStream {
  final Uint8List head;
  final List<Uint8List> packets;
  final int? finalGranulePosition;

  const _OpusStream({
    required this.head,
    required this.packets,
    this.finalGranulePosition,
  });

  Uint8List toOgg() {
    if (!_startsWith(head, utf8.encode('OpusHead')) || head.length < 19) {
      throw const FormatException('Invalid Opus identification header');
    }
    if (packets.isEmpty) throw const FormatException('No Opus packets found');

    final output = BytesBuilder(copy: false);
    final serial = DateTime.now().microsecondsSinceEpoch.toUnsigned(32);
    var sequence = 0;
    var granule = ByteData.sublistView(head).getUint16(10, Endian.little);
    var previousPageGranule = 0;

    output.add(
      _buildOggPage(
        packet: head,
        headerType: 0x02,
        granulePosition: 0,
        serial: serial,
        sequence: sequence++,
      ),
    );
    output.add(
      _buildOggPage(
        packet: _opusTags(),
        headerType: 0,
        granulePosition: 0,
        serial: serial,
        sequence: sequence++,
      ),
    );

    for (var index = 0; index < packets.length; index++) {
      final packet = packets[index];
      granule += _opusPacketSamples(packet);
      final isLast = index == packets.length - 1;
      final pageGranule = isLast && finalGranulePosition != null
          ? max(
              previousPageGranule,
              min(granule, max(finalGranulePosition!, 0)),
            )
          : granule;
      output.add(
        _buildOggPage(
          packet: packet,
          headerType: isLast ? 0x04 : 0,
          granulePosition: pageGranule,
          serial: serial,
          sequence: sequence++,
        ),
      );
      previousPageGranule = pageGranule;
    }
    return output.takeBytes();
  }
}

class _WebmOpusReader {
  final Uint8List bytes;
  late final ByteData _data = ByteData.sublistView(bytes);
  int _timecodeScale = 1000000;
  double? _duration;
  int? _trackNumber;
  int _channels = 1;
  int _preSkip = 312;
  Uint8List? _opusHead;
  final List<Uint8List> _packets = [];

  _WebmOpusReader(this.bytes);

  Uint8List convert() {
    _parseElements(0, bytes.length);
    final trackNumber = _trackNumber;
    if (trackNumber == null || _packets.isEmpty) {
      throw const FormatException('No Opus audio track found in WebM');
    }
    final head = _opusHead ?? _createOpusHead(_channels, _preSkip, 48000);
    final duration = _duration;
    final finalGranule = duration == null
        ? null
        : _preSkip + (duration * _timecodeScale / 1000000000 * 48000).round();
    return _OpusStream(
      head: head,
      packets: _packets,
      finalGranulePosition: finalGranule,
    ).toOgg();
  }

  void _parseElements(int start, int end) {
    var offset = start;
    while (offset < end) {
      final id = _readVint(offset, keepMarker: true);
      if (id == null) return;
      final size = _readVint(offset + id.length);
      if (size == null) return;
      final dataStart = offset + id.length + size.length;
      final dataEnd = size.unknown ? end : min(end, dataStart + size.value);
      if (dataStart > dataEnd || dataEnd > bytes.length) return;

      switch (id.value) {
        case 0x18538067: // Segment
        case 0x1549a966: // Info
        case 0x1654ae6b: // Tracks
          _parseElements(dataStart, dataEnd);
        case 0x2ad7b1: // TimecodeScale
          _timecodeScale = _readUnsigned(dataStart, dataEnd);
        case 0x4489: // Duration
          _duration = _readFloat(dataStart, dataEnd);
        case 0xae: // TrackEntry
          _parseTrackEntry(dataStart, dataEnd);
        case 0x1f43b675: // Cluster
          _parseCluster(dataStart, dataEnd);
      }
      if (dataEnd <= offset) return;
      offset = dataEnd;
    }
  }

  void _parseTrackEntry(int start, int end) {
    int? number;
    String? codec;
    Uint8List? codecPrivate;
    var channels = 1;
    var codecDelay = 6500000;
    _walkChildren(start, end, (id, dataStart, dataEnd) {
      switch (id) {
        case 0xd7:
          number = _readUnsigned(dataStart, dataEnd);
        case 0x86:
          codec = utf8.decode(bytes.sublist(dataStart, dataEnd));
        case 0x63a2:
          codecPrivate = Uint8List.sublistView(bytes, dataStart, dataEnd);
        case 0x9f:
          channels = _readUnsigned(dataStart, dataEnd);
        case 0x56aa:
          codecDelay = _readUnsigned(dataStart, dataEnd);
      }
    }, recursiveContainers: const {0xe1});
    if (codec != 'A_OPUS' || number == null) return;
    _trackNumber = number;
    _channels = channels;
    _preSkip = (codecDelay * 48000 / 1000000000).round();
    if (codecPrivate != null &&
        _startsWith(codecPrivate!, utf8.encode('OpusHead'))) {
      _opusHead = Uint8List.fromList(codecPrivate!);
      if (_opusHead!.length >= 12) {
        _channels = _opusHead![9];
        _preSkip = ByteData.sublistView(
          _opusHead!,
        ).getUint16(10, Endian.little);
      }
    }
  }

  void _parseCluster(int start, int end) {
    final children = _children(start, end);
    for (final child in children) {
      if (child.id == 0xa3) {
        _parseBlock(child.start, child.end);
      } else if (child.id == 0xa0) {
        for (final block in _children(child.start, child.end)) {
          if (block.id == 0xa1) {
            _parseBlock(block.start, block.end);
          }
        }
      }
    }
  }

  void _parseBlock(int start, int end) {
    final track = _readVint(start);
    if (track == null || track.value != _trackNumber) return;
    var offset = start + track.length;
    if (offset + 3 > end) return;
    offset += 2;
    final flags = bytes[offset++];
    final lacing = (flags & 0x06) >> 1;
    _packets.addAll(_readLacedPackets(offset, end, lacing));
  }

  List<Uint8List> _readLacedPackets(int start, int end, int lacing) {
    if (lacing == 0) return [Uint8List.sublistView(bytes, start, end)];
    if (start >= end) throw const FormatException('Invalid WebM lacing');
    final packetCount = bytes[start] + 1;
    var offset = start + 1;
    final sizes = <int>[];

    if (lacing == 1) {
      for (var index = 0; index < packetCount - 1; index++) {
        var size = 0;
        int value;
        do {
          if (offset >= end) throw const FormatException('Invalid Xiph lacing');
          value = bytes[offset++];
          size += value;
        } while (value == 255);
        sizes.add(size);
      }
    } else if (lacing == 2) {
      final remaining = end - offset;
      if (remaining % packetCount != 0) {
        throw const FormatException('Invalid fixed WebM lacing');
      }
      sizes.addAll(List.filled(packetCount - 1, remaining ~/ packetCount));
    } else {
      final first = _readVint(offset);
      if (first == null) throw const FormatException('Invalid EBML lacing');
      offset += first.length;
      sizes.add(first.value);
      for (var index = 1; index < packetCount - 1; index++) {
        final delta = _readVint(offset);
        if (delta == null) throw const FormatException('Invalid EBML lacing');
        offset += delta.length;
        final bias = (1 << (7 * delta.length - 1)) - 1;
        sizes.add(sizes.last + delta.value - bias);
      }
    }

    final finalSize =
        end - offset - sizes.fold<int>(0, (sum, size) => sum + size);
    sizes.add(finalSize);
    final packets = <Uint8List>[];
    for (final size in sizes) {
      if (size <= 0 || offset + size > end) {
        throw const FormatException('Invalid WebM packet size');
      }
      packets.add(Uint8List.sublistView(bytes, offset, offset + size));
      offset += size;
    }
    return packets;
  }

  void _walkChildren(
    int start,
    int end,
    void Function(int id, int start, int end) visitor, {
    Set<int> recursiveContainers = const {},
  }) {
    for (final child in _children(start, end)) {
      visitor(child.id, child.start, child.end);
      if (recursiveContainers.contains(child.id)) {
        _walkChildren(
          child.start,
          child.end,
          visitor,
          recursiveContainers: recursiveContainers,
        );
      }
    }
  }

  List<_EbmlElement> _children(int start, int end) {
    final result = <_EbmlElement>[];
    var offset = start;
    while (offset < end) {
      final id = _readVint(offset, keepMarker: true);
      if (id == null) break;
      final size = _readVint(offset + id.length);
      if (size == null) break;
      final dataStart = offset + id.length + size.length;
      final dataEnd = size.unknown ? end : min(end, dataStart + size.value);
      if (dataStart > dataEnd || dataEnd > bytes.length) break;
      result.add(_EbmlElement(id.value, dataStart, dataEnd));
      if (dataEnd <= offset) break;
      offset = dataEnd;
    }
    return result;
  }

  _Vint? _readVint(int offset, {bool keepMarker = false}) {
    if (offset >= bytes.length) return null;
    final first = bytes[offset];
    var mask = 0x80;
    var length = 1;
    while (length <= 8 && (first & mask) == 0) {
      mask >>= 1;
      length++;
    }
    if (length > 8 || offset + length > bytes.length) return null;
    var value = keepMarker ? first : first & (mask - 1);
    for (var index = 1; index < length; index++) {
      value = (value << 8) | bytes[offset + index];
    }
    final unknown = !keepMarker && value == (1 << (7 * length)) - 1;
    return _Vint(value, length, unknown);
  }

  int _readUnsigned(int start, int end) {
    var value = 0;
    for (var offset = start; offset < end; offset++) {
      value = (value << 8) | bytes[offset];
    }
    return value;
  }

  double? _readFloat(int start, int end) {
    final length = end - start;
    if (length == 4) return _data.getFloat32(start, Endian.big);
    if (length == 8) return _data.getFloat64(start, Endian.big);
    return null;
  }
}

class _CafOpusReader {
  final Uint8List bytes;
  late final ByteData _data = ByteData.sublistView(bytes);

  _CafOpusReader(this.bytes);

  Uint8List convert() {
    Uint8List? audioData;
    Uint8List? packetTable;
    var channels = 1;
    var sampleRate = 48000;
    var bytesPerPacket = 0;
    var packetCount = 0;
    var validFrames = 0;
    var primingFrames = 312;

    var offset = 8;
    while (offset + 12 <= bytes.length) {
      final type = ascii.decode(bytes.sublist(offset, offset + 4));
      final size = _data.getInt64(offset + 4, Endian.big);
      offset += 12;
      if (size < 0 || offset + size > bytes.length) {
        throw const FormatException('Invalid CAF chunk size');
      }
      final end = offset + size;
      switch (type) {
        case 'desc':
          if (size < 32) throw const FormatException('Invalid CAF description');
          sampleRate = _data.getFloat64(offset, Endian.big).round();
          final codec = ascii.decode(bytes.sublist(offset + 8, offset + 12));
          if (codec != 'opus') throw const FormatException('CAF is not Opus');
          bytesPerPacket = _data.getUint32(offset + 16, Endian.big);
          channels = _data.getUint32(offset + 24, Endian.big);
        case 'data':
          if (size < 4) throw const FormatException('Invalid CAF audio data');
          audioData = Uint8List.sublistView(bytes, offset + 4, end);
        case 'pakt':
          if (size < 24) {
            throw const FormatException('Invalid CAF packet table');
          }
          packetCount = _data.getUint64(offset, Endian.big);
          validFrames = _data.getUint64(offset + 8, Endian.big);
          primingFrames = _data.getUint32(offset + 16, Endian.big);
          packetTable = Uint8List.sublistView(bytes, offset + 24, end);
      }
      offset = end;
    }
    if (audioData == null || packetCount <= 0) {
      throw const FormatException('CAF contains no Opus packets');
    }

    final sizes = <int>[];
    if (bytesPerPacket > 0) {
      sizes.addAll(List.filled(packetCount, bytesPerPacket));
    } else {
      final table = packetTable;
      if (table == null) {
        throw const FormatException('CAF packet table is missing');
      }
      var tableOffset = 0;
      while (sizes.length < packetCount) {
        var value = 0;
        int byte;
        do {
          if (tableOffset >= table.length) {
            throw const FormatException('CAF packet table is incomplete');
          }
          byte = table[tableOffset++];
          value = (value << 7) | (byte & 0x7f);
        } while ((byte & 0x80) != 0);
        sizes.add(value);
      }
    }

    final packets = <Uint8List>[];
    var packetOffset = 0;
    for (final size in sizes) {
      if (size <= 0 || packetOffset + size > audioData.length) {
        throw const FormatException('Invalid CAF Opus packet size');
      }
      packets.add(
        Uint8List.sublistView(audioData, packetOffset, packetOffset + size),
      );
      packetOffset += size;
    }
    final preSkip = primingFrames.clamp(0, 65535);
    return _OpusStream(
      head: _createOpusHead(channels, preSkip, sampleRate),
      packets: packets,
      finalGranulePosition: validFrames > 0 ? preSkip + validFrames : null,
    ).toOgg();
  }
}

Uint8List _createOpusHead(int channels, int preSkip, int sampleRate) {
  final result = Uint8List(19);
  result.setRange(0, 8, utf8.encode('OpusHead'));
  result[8] = 1;
  result[9] = channels.clamp(1, 255);
  final data = ByteData.sublistView(result);
  data.setUint16(10, preSkip.clamp(0, 65535), Endian.little);
  data.setUint32(12, sampleRate, Endian.little);
  data.setInt16(16, 0, Endian.little);
  result[18] = 0;
  return result;
}

Uint8List _opusTags() {
  const vendor = 'FluffyChat';
  final vendorBytes = utf8.encode(vendor);
  final result = Uint8List(8 + 4 + vendorBytes.length + 4);
  result.setRange(0, 8, utf8.encode('OpusTags'));
  final data = ByteData.sublistView(result);
  data.setUint32(8, vendorBytes.length, Endian.little);
  result.setRange(12, 12 + vendorBytes.length, vendorBytes);
  data.setUint32(12 + vendorBytes.length, 0, Endian.little);
  return result;
}

int _opusPacketSamples(Uint8List packet) {
  if (packet.isEmpty) throw const FormatException('Empty Opus packet');
  final config = packet[0] >> 3;
  final samplesPerFrame = config >= 16
      ? 120 << (config & 3)
      : config >= 12
      ? 480 << (config & 1)
      : (config & 3) == 3
      ? 2880
      : 480 << (config & 3);
  final code = packet[0] & 3;
  final frames = switch (code) {
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

Uint8List _buildOggPage({
  required Uint8List packet,
  required int headerType,
  required int granulePosition,
  required int serial,
  required int sequence,
}) {
  final segments = <int>[];
  var remaining = packet.length;
  while (remaining >= 255) {
    segments.add(255);
    remaining -= 255;
  }
  segments.add(remaining);
  if (segments.length > 255) {
    throw const FormatException('Opus packet is too large for one OGG page');
  }

  final page = Uint8List(27 + segments.length + packet.length);
  page.setRange(0, 4, utf8.encode('OggS'));
  page[4] = 0;
  page[5] = headerType;
  final data = ByteData.sublistView(page);
  // ByteData.setUint64 throws at runtime in dart2js. OGG stores the granule
  // position as two little-endian 32-bit words, which is also safe on Web.
  data.setUint32(6, granulePosition.toUnsigned(32), Endian.little);
  data.setUint32(
    10,
    (granulePosition ~/ 0x100000000).toUnsigned(32),
    Endian.little,
  );
  data.setUint32(14, serial, Endian.little);
  data.setUint32(18, sequence, Endian.little);
  data.setUint32(22, 0, Endian.little);
  page[26] = segments.length;
  page.setRange(27, 27 + segments.length, segments);
  page.setRange(27 + segments.length, page.length, packet);
  data.setUint32(22, _oggCrc(page), Endian.little);
  return page;
}

int _oggCrc(Uint8List page) {
  var crc = 0;
  for (final byte in page) {
    crc = ((crc << 8) ^ _oggCrcTable[((crc >> 24) & 0xff) ^ byte]).toUnsigned(
      32,
    );
  }
  return crc;
}

final List<int> _oggCrcTable = List.generate(256, (index) {
  var value = index << 24;
  for (var bit = 0; bit < 8; bit++) {
    value = (value & 0x80000000) != 0 ? (value << 1) ^ 0x04c11db7 : value << 1;
  }
  return value.toUnsigned(32);
});

class _Vint {
  final int value;
  final int length;
  final bool unknown;

  const _Vint(this.value, this.length, this.unknown);
}

class _EbmlElement {
  final int id;
  final int start;
  final int end;

  const _EbmlElement(this.id, this.start, this.end);
}
