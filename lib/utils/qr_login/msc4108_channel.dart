// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'qr_login_payload.dart';

class QrLoginException implements Exception {
  final String reason;
  const QrLoginException(this.reason);

  @override
  String toString() => 'QrLoginException($reason)';
}

/// Unauthenticated rendezvous: never attach the phone's Matrix access token.
/// Requests don't follow redirects, and the channel has an overall deadline.
class Msc4108Transport {
  final Uri uri;
  final http.Client _http;
  final Duration pollInterval;
  final DateTime _deadline;
  String? _etag;
  bool _closed = false;

  Msc4108Transport(
    this.uri, {
    http.Client? httpClient,
    this.pollInterval = const Duration(seconds: 1),
    Duration lifetime = const Duration(minutes: 5),
  }) : _http = httpClient ?? http.Client(),
       _deadline = DateTime.now().add(lifetime) {
    if (!isSecureQrLoginUri(uri)) {
      throw const QrLoginException('insecure_channel_detected');
    }
  }

  bool get closed => _closed;

  void checkActive() {
    if (_closed) throw const QrLoginException('user_cancelled');
    if (DateTime.now().isAfter(_deadline)) {
      throw const QrLoginException('expired');
    }
  }

  Future<http.Response> _request(String method, {String? body}) async {
    checkActive();
    final request = http.Request(method, uri)..followRedirects = false;
    request.headers['accept'] = 'text/plain';
    if (method == 'PUT') {
      request.headers['content-type'] = 'text/plain';
      request.body = body!;
      request.headers['if-match'] = _etag!;
    } else if (_etag != null) {
      request.headers['if-none-match'] = _etag!;
    }
    final response = await (() async {
      final streamed = await _http.send(request);
      final bytes = <int>[];
      await for (final chunk in streamed.stream) {
        bytes.addAll(chunk);
        if (bytes.length > 65536) {
          throw const QrLoginException('unexpected_message_received');
        }
      }
      return http.Response.bytes(
        bytes,
        streamed.statusCode,
        headers: streamed.headers,
      );
    })().timeout(const Duration(seconds: 20));
    checkActive();
    if ([404, 410].contains(response.statusCode)) {
      throw const QrLoginException('expired');
    }
    if (response.statusCode == 412) {
      throw const QrLoginException('insecure_channel_detected');
    }
    if (![200, 201, 202, 204, 304].contains(response.statusCode)) {
      throw const QrLoginException('network_error');
    }
    return response;
  }

  String _readEtag(http.Response response) {
    final etag = response.headers['etag'];
    if (etag == null || etag.isEmpty) {
      throw const QrLoginException('etag_missing');
    }
    return etag;
  }

  Future<void> send(String text) async {
    if (_etag == null) {
      // The displayed QR's rendezvous has an initial empty body.
      final initial = await _request('GET');
      if (initial.statusCode != 200 || initial.bodyBytes.isNotEmpty) {
        throw const QrLoginException('insecure_channel_detected');
      }
      _etag = _readEtag(initial);
    }
    final response = await _request('PUT', body: text);
    _etag = _readEtag(response);
  }

  Future<String> receive() async {
    while (true) {
      final response = await _request('GET');
      if (response.statusCode == 200) {
        final etag = _readEtag(response);
        if (etag != _etag) {
          _etag = etag;
          if (response.headers['content-type']?.split(';').first.trim() !=
              'text/plain') {
            throw const QrLoginException('unexpected_message_received');
          }
          return utf8.decode(response.bodyBytes);
        }
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  void close() {
    _closed = true;
    _http.close();
  }
}

/// MSC4108 ECIES, matching vodozemac (HKDF-SHA512, directional keys,
/// independent little-endian 96-bit nonce counters, ChaCha20-Poly1305).
/// The JS SDK's older inline SHA256 / shared-nonce comments are obsolete.
class Msc4108Cipher {
  final SecretKey _sendKey;
  final SecretKey _receiveKey;
  final String checkCode;
  final String initialMessage;
  final _aead = Chacha20.poly1305Aead();
  int _sendNonce = 1;
  int _receiveNonce = 0;

  Msc4108Cipher._(
    this._sendKey,
    this._receiveKey,
    this.checkCode,
    this.initialMessage,
  );

  static String _base64(List<int> bytes) =>
      base64Encode(bytes).replaceAll('=', '');

  static Future<Msc4108Cipher> create(List<int> theirKey) async {
    final x25519 = X25519();
    final pair = await x25519.newKeyPair();
    final publicKey = await pair.extractPublicKey();
    final shared = await x25519.sharedSecretKey(
      keyPair: pair,
      remotePublicKey: SimplePublicKey(theirKey, type: KeyPairType.x25519),
    );
    final sharedBytes = await shared.extractBytes();
    if (sharedBytes.every((byte) => byte == 0)) {
      throw const QrLoginException('insecure_channel_detected');
    }
    final suffix = '|${_base64(theirKey)}|${_base64(publicKey.bytes)}';
    Future<SecretKey> derive(String purpose, int length) =>
        Hkdf(hmac: Hmac.sha512(), outputLength: length).deriveKey(
          secretKey: shared,
          nonce: const [],
          info: utf8.encode('MATRIX_QR_CODE_LOGIN_$purpose$suffix'),
        );
    final sendKey = await derive('ENCKEY_S', 32);
    final receiveKey = await derive('ENCKEY_G', 32);
    final check = await (await derive('CHECKCODE', 2)).extractBytes();
    final initial = await Chacha20.poly1305Aead().encrypt(
      utf8.encode('MATRIX_QR_CODE_LOGIN_INITIATE'),
      secretKey: sendKey,
      nonce: Uint8List(12),
    );
    return Msc4108Cipher._(
      sendKey,
      receiveKey,
      check.map((byte) => '${byte % 10}').join(),
      '${_base64([...initial.cipherText, ...initial.mac.bytes])}|${_base64(publicKey.bytes)}',
    );
  }

  Uint8List _nonce(int value) =>
      Uint8List(12)..buffer.asByteData().setUint64(0, value, Endian.little);

  Future<String> encrypt(String text) async {
    final box = await _aead.encrypt(
      utf8.encode(text),
      secretKey: _sendKey,
      nonce: _nonce(_sendNonce++),
    );
    return _base64([...box.cipherText, ...box.mac.bytes]);
  }

  Future<String> decrypt(String text) async {
    try {
      final bytes = base64Decode(base64.normalize(text));
      if (bytes.length < 16) throw const FormatException();
      final clear = await _aead.decrypt(
        SecretBox(
          bytes.sublist(0, bytes.length - 16),
          nonce: _nonce(_receiveNonce++),
          mac: Mac(bytes.sublist(bytes.length - 16)),
        ),
        secretKey: _receiveKey,
      );
      return utf8.decode(clear);
    } catch (_) {
      throw const QrLoginException('insecure_channel_detected');
    }
  }

  void dispose() {
    _sendKey.destroy();
    _receiveKey.destroy();
  }
}

class Msc4108Channel {
  final Msc4108Transport transport;
  Msc4108Cipher? _cipher;
  Msc4108Channel(this.transport);

  String get checkCode => _cipher!.checkCode;

  Future<void> connect(List<int> publicKey) async {
    if (_cipher != null) throw StateError('Already connected');
    final cipher = _cipher = await Msc4108Cipher.create(publicKey);
    await transport.send(cipher.initialMessage);
    if (await cipher.decrypt(await transport.receive()) !=
        'MATRIX_QR_CODE_LOGIN_OK') {
      throw const QrLoginException('insecure_channel_detected');
    }
  }

  Future<void> send(Map<String, Object?> payload) async {
    transport.checkActive();
    await transport.send(await _cipher!.encrypt(jsonEncode(payload)));
  }

  Future<Map<String, Object?>> receive() async {
    final value = jsonDecode(await _cipher!.decrypt(await transport.receive()));
    if (value is! Map<String, Object?>) {
      throw const QrLoginException('unexpected_message_received');
    }
    if (value['type'] == 'm.login.failure') {
      throw QrLoginException(
        value['reason'] is String
            ? value['reason'] as String
            : 'unexpected_message_received',
      );
    }
    return value;
  }

  void close() {
    transport.close();
    _cipher?.dispose();
    _cipher = null;
  }
}
