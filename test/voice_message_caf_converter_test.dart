// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:fluffychat/utils/voice_message_caf_converter.dart';
import 'package:fluffychat/utils/voice_message_ogg_converter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('preserves large Opus packets and stereo channels in CAF', () {
    final packets = [_packet(0xf8, 300), _packet(0xf8, 510)];
    final caf = convertOggOpusToCaf(_ogg(packets, channels: 2));
    final chunks = _cafChunks(caf);
    final desc = ByteData.sublistView(chunks['desc']!);
    expect(desc.getFloat64(0, Endian.big), 48000);
    expect(desc.getUint32(20, Endian.big), 960);
    expect(desc.getUint32(24, Endian.big), 2);
    expect(chunks['data']!.sublist(4), [...packets[0], ...packets[1]]);
    // 300 and 510 encoded as CAF varints, without wrapping at 255.
    expect(chunks['pakt']!.sublist(24), [0x82, 0x2c, 0x83, 0x7e]);
  });

  test('uses 48 kHz regardless of the informational OGG input rate', () {
    for (final rate in [0, 8000, 16000, 24000, 44100, 48000]) {
      final caf = convertOggOpusToCaf(
        _ogg([_packet(0xf8, 20), _packet(0xf8, 20)], sampleRate: rate),
      );
      final chunks = _cafChunks(caf);
      expect(ByteData.sublistView(chunks['desc']!).getFloat64(0), 48000);
      final table = ByteData.sublistView(chunks['pakt']!);
      expect(table.getInt64(8), 1608);
      expect(table.getInt32(16), 312);
      expect(table.getInt32(20), 0);
    }
  });

  test('preserves end trim and packet durations for mixed Opus frames', () {
    final ogg = _ogg([_packet(0xf8, 300), _packet(0xf9, 400)]);
    // 960 + 1920 decoded frames, with 312 priming and 120 end padding.
    _setLastGranule(ogg, 2760);
    final chunks = _cafChunks(convertOggOpusToCaf(ogg));
    expect(ByteData.sublistView(chunks['desc']!).getUint32(20), 0);
    final table = ByteData.sublistView(chunks['pakt']!);
    expect(table.getInt64(8), 2448);
    expect(table.getInt32(16), 312);
    expect(table.getInt32(20), 120);
    expect(chunks['pakt']!.sublist(24), [
      0x82, 0x2c, // 300 bytes.
      0x83, 0x10, // 400 bytes.
    ]);
  });

  test('reassembles an Opus packet continued on the next OGG page', () {
    final packet = _packet(0xf8, 300);
    final ogg = _ogg([packet]);
    final starts = _pageOffsets(ogg);
    final audioPage = ogg.sublist(starts[2]);
    final first = Uint8List(27 + 1 + 255)
      ..setRange(0, 27, audioPage.sublist(0, 27));
    first[5] = 0;
    first[26] = 1;
    first[27] = 255;
    first.setRange(28, first.length, packet.sublist(0, 255));
    final second = Uint8List(27 + 1 + 45)
      ..setRange(0, 27, audioPage.sublist(0, 27));
    second[5] = 5; // Continued packet and end of stream.
    ByteData.sublistView(second).setUint32(18, 3, Endian.little);
    second[26] = 1;
    second[27] = 45;
    second.setRange(28, second.length, packet.sublist(255));
    final continued = Uint8List.fromList([
      ...ogg.sublist(0, starts[2]),
      ...first,
      ...second,
    ]);
    final chunks = _cafChunks(convertOggOpusToCaf(continued));
    expect(chunks['data']!.sublist(4), packet);
    expect(ByteData.sublistView(chunks['pakt']!).getInt64(0), 1);
    expect(chunks['pakt']!.sublist(24), [0x82, 0x2c]);
  });

  test('rejects truncated OGG instead of producing a partial CAF', () {
    final ogg = _ogg([_packet(0xf8, 300)]);
    expect(
      () => convertOggOpusToCaf(ogg.sublist(0, ogg.length - 1)),
      throwsFormatException,
    );
    ogg[_pageOffsets(ogg).last + 5] = 0; // Missing end-of-stream marker.
    expect(() => convertOggOpusToCaf(ogg), throwsFormatException);
  });

  test('OGG page granules do not count pre-skip twice', () {
    final ogg = _ogg([_packet(0xf8, 20), _packet(0xf8, 20)]);
    final starts = _pageOffsets(ogg);
    expect(
      ByteData.sublistView(ogg, starts[2]).getInt64(6, Endian.little),
      960,
    );
    expect(
      ByteData.sublistView(ogg, starts[3]).getInt64(6, Endian.little),
      1920,
    );
  });

  test('Apple CAF frame counts are scaled to OGG 48 kHz units', () async {
    final packets = List.generate(50, (_) => _packet(0xf8, 300));
    final caf = convertOggOpusToCaf(_ogg(packets));
    var offset = 8;
    while (offset < caf.length) {
      final type = ascii.decode(caf.sublist(offset, offset + 4));
      final size = ByteData.sublistView(caf).getInt64(offset + 4);
      final chunk = ByteData.sublistView(caf, offset + 12);
      if (type == 'desc') {
        chunk.setFloat64(0, 24000);
        chunk.setUint32(20, 480);
      } else if (type == 'pakt') {
        chunk.setInt64(8, 23844);
        chunk.setInt32(16, 156);
      }
      offset += 12 + size;
    }
    final ogg = await normalizeVoiceMessageToOgg(caf);
    final head = ByteData.sublistView(ogg, 28);
    expect(head.getUint16(10, Endian.little), 312);
    final last = _pageOffsets(ogg).last;
    expect(ByteData.sublistView(ogg, last).getInt64(6, Endian.little), 48000);
  });
}

Uint8List _packet(int toc, int size) => Uint8List(size)..[0] = toc;

Uint8List _ogg(
  List<Uint8List> packets, {
  int channels = 1,
  int sampleRate = 48000,
}) => packageOpusPacketsAsOgg(
  packets: packets,
  channels: channels,
  inputSampleRate: sampleRate,
  validSamplesPerChannel: packets.fold<int>(
    -312,
    (sum, packet) => sum + ((packet[0] & 3) == 1 ? 1920 : 960),
  ),
);

List<int> _pageOffsets(Uint8List ogg) {
  final result = <int>[];
  var offset = 0;
  while (offset < ogg.length) {
    result.add(offset);
    final count = ogg[offset + 26];
    final size = ogg
        .sublist(offset + 27, offset + 27 + count)
        .fold<int>(0, (sum, value) => sum + value);
    offset += 27 + count + size;
  }
  return result;
}

void _setLastGranule(Uint8List ogg, int value) => ByteData.sublistView(
  ogg,
  _pageOffsets(ogg).last,
).setInt64(6, value, Endian.little);

Map<String, Uint8List> _cafChunks(Uint8List caf) {
  expect(ascii.decode(caf.sublist(0, 4)), 'caff');
  final result = <String, Uint8List>{};
  var offset = 8;
  while (offset < caf.length) {
    final type = ascii.decode(caf.sublist(offset, offset + 4));
    final size = ByteData.sublistView(caf).getInt64(offset + 4);
    result[type] = caf.sublist(offset + 12, offset + 12 + size);
    offset += 12 + size;
  }
  return result;
}
