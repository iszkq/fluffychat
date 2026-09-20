// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:opus_codec_dart/opus_codec_dart.dart';
import 'package:opus_codec_web/opus_codec_web.dart';

import 'voice_message_ogg_converter.dart' show packageOpusPacketsAsOgg;

const _opusSampleRate = 48000;
const _opusFrameSamples = 960; // 20 ms at 48 kHz.

Future<void>? _opusInitialization;

Future<void> _initializeOpus() => _opusInitialization ??= () async {
  initOpus(await OpusFlutterWeb().load());
}();

/// Encodes the PCM16 WAV produced by record_web as OGG/Opus.
///
/// Browsers do not offer a consistent native OGG recorder. Element Web solves
/// this with a WebAssembly Opus encoder; this follows the same design while
/// retaining record_web for microphone permissions, pausing and metering.
Future<Uint8List> encodeWavVoiceMessageToOgg(Uint8List bytes) async {
  final wav = _Pcm16Wav.parse(bytes);
  if (wav.channels < 1 || wav.channels > 2) {
    throw const FormatException('Only mono or stereo WAV is supported');
  }
  if (wav.sampleRate <= 0 || wav.frameCount <= 0) {
    throw const FormatException('WAV contains no audio samples');
  }

  await _initializeOpus();
  final encoder = SimpleOpusEncoder(
    sampleRate: _opusSampleRate,
    channels: wav.channels,
    application: Application.voip,
  );
  final outputFrameCount = (wav.frameCount * _opusSampleRate / wav.sampleRate)
      .round();
  final packetCount = (outputFrameCount / _opusFrameSamples).ceil();
  final packets = <Uint8List>[];

  try {
    for (var packetIndex = 0; packetIndex < packetCount; packetIndex++) {
      final frame = Int16List(_opusFrameSamples * wav.channels);
      final outputStart = packetIndex * _opusFrameSamples;
      for (var sample = 0; sample < _opusFrameSamples; sample++) {
        final outputFrame = outputStart + sample;
        if (outputFrame >= outputFrameCount) break;
        final sourcePosition = outputFrame * wav.sampleRate / _opusSampleRate;
        final sourceFrame = sourcePosition.floor();
        final nextFrame = min(sourceFrame + 1, wav.frameCount - 1);
        final fraction = sourcePosition - sourceFrame;
        for (var channel = 0; channel < wav.channels; channel++) {
          final first = wav.sample(sourceFrame, channel);
          final second = wav.sample(nextFrame, channel);
          frame[sample * wav.channels +
              channel] = (first + (second - first) * fraction).round().clamp(
            -32768,
            32767,
          );
        }
      }
      packets.add(encoder.encode(input: frame));

      // Long recordings should not lock Flutter's UI while encoding.
      if (packetIndex % 50 == 49) await Future<void>.delayed(Duration.zero);
    }
  } finally {
    encoder.destroy();
  }

  return packageOpusPacketsAsOgg(
    packets: packets,
    channels: wav.channels,
    inputSampleRate: wav.sampleRate,
    validSamplesPerChannel: outputFrameCount,
  );
}

class _Pcm16Wav {
  final Uint8List bytes;
  final ByteData data;
  final int dataOffset;
  final int dataLength;
  final int sampleRate;
  final int channels;

  _Pcm16Wav({
    required this.bytes,
    required this.dataOffset,
    required this.dataLength,
    required this.sampleRate,
    required this.channels,
  }) : data = ByteData.sublistView(bytes);

  int get frameCount => dataLength ~/ (channels * 2);

  int sample(int frame, int channel) => data.getInt16(
    dataOffset + (frame * channels + channel) * 2,
    Endian.little,
  );

  static _Pcm16Wav parse(Uint8List bytes) {
    if (bytes.length < 44 ||
        ascii.decode(bytes.sublist(0, 4)) != 'RIFF' ||
        ascii.decode(bytes.sublist(8, 12)) != 'WAVE') {
      throw const FormatException('Invalid WAV recording');
    }
    final data = ByteData.sublistView(bytes);
    int? sampleRate;
    int? channels;
    int? dataOffset;
    int? dataLength;
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = ascii.decode(bytes.sublist(offset, offset + 4));
      final size = data.getUint32(offset + 4, Endian.little);
      final chunkStart = offset + 8;
      final chunkEnd = chunkStart + size;
      if (chunkEnd > bytes.length) {
        throw const FormatException('Invalid WAV chunk size');
      }
      if (id == 'fmt ') {
        if (size < 16 || data.getUint16(chunkStart, Endian.little) != 1) {
          throw const FormatException('WAV recording is not PCM');
        }
        channels = data.getUint16(chunkStart + 2, Endian.little);
        sampleRate = data.getUint32(chunkStart + 4, Endian.little);
        if (data.getUint16(chunkStart + 14, Endian.little) != 16) {
          throw const FormatException('WAV recording is not PCM16');
        }
      } else if (id == 'data') {
        dataOffset = chunkStart;
        dataLength = size;
      }
      offset = chunkEnd + (size.isOdd ? 1 : 0);
    }
    if (sampleRate == null ||
        channels == null ||
        dataOffset == null ||
        dataLength == null) {
      throw const FormatException('WAV is missing format or audio data');
    }
    return _Pcm16Wav(
      bytes: bytes,
      dataOffset: dataOffset,
      dataLength: dataLength,
      sampleRate: sampleRate,
      channels: channels,
    );
  }
}
