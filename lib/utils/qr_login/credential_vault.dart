// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const loginCredentialsAccountDataType = 'org.mxchat.login_credentials.v1';

class CredentialVaultException implements Exception {
  final String reason;
  const CredentialVaultException(this.reason);

  @override
  String toString() => 'CredentialVaultException($reason)';
}

/// A copy of an existing private cross-signing seed, never a new stored secret.
class CredentialWrappingKey {
  final String id;
  final Uint8List seed;
  CredentialWrappingKey(this.id, this.seed);
}

/// Only ciphertext is passed to account data (which Matrix also caches locally).
/// The plaintext password is deliberately excluded from SSSS's local cache.
class CredentialVault {
  final String userId;
  final String homeserver;
  final Future<CredentialWrappingKey?> Function() loadWrappingKey;
  final Future<Map<String, Object?>> Function() readAccountData;
  final Future<void> Function(Map<String, Object?> content) writeAccountData;

  CredentialVault({
    required this.userId,
    required this.homeserver,
    required this.loadWrappingKey,
    required this.readAccountData,
    required this.writeAccountData,
  });

  List<int> _context(String keyId) => utf8.encode(
    // Matrix user IDs include the identity's server. Regional API entrances
    // for that same identity must still be able to open the same record.
    jsonEncode([loginCredentialsAccountDataType, userId, keyId]),
  );

  Future<SecretKey> _derive(CredentialWrappingKey key) async {
    try {
      if (key.seed.length != 32) {
        throw const CredentialVaultException('keys_locked');
      }
      return await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: SecretKey(key.seed),
        nonce: const [],
        info: _context(key.id),
      );
    } finally {
      key.seed.fillRange(0, key.seed.length, 0);
    }
  }

  Future<void> save(String password) async {
    if (password.isEmpty || utf8.encode(password).length > 16384) {
      throw const CredentialVaultException('password_not_available');
    }
    final wrapping = await loadWrappingKey();
    if (wrapping == null) {
      throw const CredentialVaultException('keys_locked');
    }
    final key = await _derive(wrapping);
    try {
      final box = await AesGcm.with256bits().encrypt(
        utf8.encode(password),
        secretKey: key,
        aad: _context(wrapping.id),
      );
      await writeAccountData({
        'version': 1,
        'algorithm': 'hkdf-sha256-aes-256-gcm',
        'key_id': wrapping.id,
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      });
    } finally {
      key.destroy();
    }
  }

  Future<String> load() async {
    // Read the server, rather than a potentially stale /sync cache after a
    // password change on another device.
    final content = await readAccountData();
    if (content['version'] != 1 ||
        content['algorithm'] != 'hkdf-sha256-aes-256-gcm') {
      throw const CredentialVaultException('password_not_available');
    }
    final wrapping = await loadWrappingKey();
    if (wrapping == null) {
      throw const CredentialVaultException('keys_locked');
    }
    if (content['key_id'] != wrapping.id) {
      wrapping.seed.fillRange(0, wrapping.seed.length, 0);
      throw const CredentialVaultException('credentials_key_changed');
    }
    final key = await _derive(wrapping);
    try {
      Uint8List bytes(String field) {
        final value = content[field];
        if (value is! String || value.length > 32768) {
          throw const FormatException();
        }
        return base64Decode(value);
      }

      final nonce = bytes('nonce');
      final mac = bytes('mac');
      if (nonce.length != 12 || mac.length != 16) {
        throw const FormatException();
      }
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(bytes('ciphertext'), nonce: nonce, mac: Mac(mac)),
        secretKey: key,
        aad: _context(wrapping.id),
      );
      try {
        final password = utf8.decode(clear);
        if (password.isEmpty) throw const FormatException();
        return password;
      } finally {
        clear.fillRange(0, clear.length, 0);
      }
    } catch (_) {
      throw const CredentialVaultException('credentials_corrupt');
    } finally {
      key.destroy();
    }
  }
}
