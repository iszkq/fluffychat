// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

class VoiceTranscriptionNotConfiguredException implements Exception {}

class VoiceTranscriptionException implements Exception {
  final int? statusCode;
  final String message;

  const VoiceTranscriptionException(this.message, {this.statusCode});

  @override
  String toString() => statusCode == null
      ? 'VoiceTranscriptionException: $message'
      : 'VoiceTranscriptionException ($statusCode): $message';
}

class VoiceTranscriptionService {
  static const int maxFileSize = 25 * 1024 * 1024;

  const VoiceTranscriptionService();

  Uri _resolveEndpoint() {
    final value = AppSettings.voiceTranscriptionEndpoint.value.trim();
    if (value.isEmpty) throw VoiceTranscriptionNotConfiguredException();

    final endpoint = Uri.tryParse(value);
    if (endpoint == null) throw VoiceTranscriptionNotConfiguredException();
    if (endpoint.hasScheme) return endpoint;
    if (!kIsWeb) throw VoiceTranscriptionNotConfiguredException();
    return Uri.base.resolveUri(endpoint);
  }

  Future<String> transcribe(MatrixFile audioFile) async {
    if (audioFile.bytes.length > maxFileSize) {
      throw const VoiceTranscriptionException(
        'The audio file exceeds the 25 MB transcription limit.',
      );
    }

    final request = http.MultipartRequest('POST', _resolveEndpoint())
      ..headers['Accept'] = 'application/json'
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          audioFile.bytes,
          filename: audioFile.name,
        ),
      );

    final streamedResponse = await request.send().timeout(
      const Duration(seconds: 90),
    );
    final response = await http.Response.fromStream(streamedResponse);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VoiceTranscriptionException(
        _readError(response.body),
        statusCode: response.statusCode,
      );
    }

    try {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is Map<String, Object?>) {
        final text = json['text'];
        if (text is String && text.trim().isNotEmpty) return text.trim();
      }
    } catch (_) {
      final text = utf8.decode(response.bodyBytes).trim();
      if (text.isNotEmpty) return text;
    }
    throw const VoiceTranscriptionException(
      'The transcription service returned an empty response.',
    );
  }

  String _readError(String body) {
    try {
      final json = jsonDecode(body);
      if (json is Map<String, Object?>) {
        final error = json['error'];
        if (error is String) return error;
        if (error is Map<String, Object?> && error['message'] is String) {
          return error['message'] as String;
        }
      }
    } catch (_) {}
    return body.trim().isEmpty ? 'Unknown transcription error.' : body.trim();
  }
}
