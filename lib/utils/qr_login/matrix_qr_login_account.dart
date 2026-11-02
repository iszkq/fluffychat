// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

import 'msc4108_channel.dart';
import 'qr_login_existing_device.dart';

class MatrixQrLoginAccount extends QrLoginAccount {
  final Client client;
  @override
  final String userId;
  final String? _deviceId;
  @override
  String? get deviceId => _deviceId;
  @override
  bool get supportsVerificationHandoff => true;
  String? _masterKey;
  bool _triedSecureStorage = false;
  bool _cleared = false;

  MatrixQrLoginAccount(this.client)
    : userId = client.userID ?? '',
      _deviceId = client.deviceID;

  void _checkAccount() {
    if (_cleared ||
        !client.isLogged() ||
        client.userID != userId ||
        client.deviceID != _deviceId) {
      throw const QrLoginException('account_changed');
    }
  }

  @override
  Future<QrLoginAuthMetadata> authMetadata() async {
    _checkAccount();
    GetAuthMetadataResponse metadata;
    try {
      metadata = await client.getAuthMetadata();
    } on MatrixException catch (error) {
      if (!['M_UNRECOGNIZED', 'M_NOT_FOUND'].contains(error.errcode)) rethrow;
      metadata = GetAuthMetadataResponse.fromJson(
        await client.request(
          RequestType.GET,
          '/client/unstable/org.matrix.msc2965/auth_metadata',
        ),
      );
    }
    return QrLoginAuthMetadata(
      metadata.issuer,
      supportsDeviceGrant: metadata.grantTypesSupported.contains(
        'urn:ietf:params:oauth:grant-type:device_code',
      ),
    );
  }

  @override
  Future<void> ensureSecretsAvailable() async {
    _checkAccount();
    await client.accountDataLoading;
    await client.userDeviceKeysLoading;
    final encryption = client.encryption;
    // Some clients may have explicitly cached this seed, although Dart SDK's
    // default cacheTypes omit it. Validate it before use during export.
    _masterKey ??= await encryption?.ssss.getCached(
      EventTypes.CrossSigningMasterKey,
    );
    // The SDK deliberately doesn't cache the master seed. Reuse only the
    // recovery key the user already chose to keep in OS secure storage.
    if (encryption != null && _masterKey == null && !_triedSecureStorage) {
      _triedSecureStorage = true;
      try {
        final recovery = await const FlutterSecureStorage().read(
          key: 'ssss_recovery_key_$userId',
        );
        if (recovery != null && recovery.isNotEmpty) {
          await unlockSecrets(recovery);
        }
      } catch (_) {
        /* Ask for local recovery in the dialog instead. */
      }
    }
    _checkAccount();
    if (encryption == null || !encryption.crossSigning.isSelfSigned) {
      throw const QrLoginException('keys_locked');
    }
    for (final type in [
      EventTypes.CrossSigningSelfSigning,
      EventTypes.CrossSigningUserSigning,
    ]) {
      if (await encryption.ssss.getCached(type) == null) {
        throw const QrLoginException('keys_locked');
      }
    }
    if (_masterKey == null) throw const QrLoginException('keys_locked');
  }

  @override
  Future<void> unlockSecrets(String recoveryKeyOrPassphrase) async {
    _checkAccount();
    final encryption = client.encryption;
    if (encryption == null) throw const QrLoginException('keys_locked');
    OpenSSSS? handle;
    try {
      handle = encryption.ssss.open(EventTypes.CrossSigningMasterKey);
      await handle.unlock(
        keyOrPassphrase: recoveryKeyOrPassphrase,
        postUnlock: false,
      );
      final master = await handle.getStored(EventTypes.CrossSigningMasterKey);
      final seed = base64Decode(base64.normalize(master));
      final key = await Ed25519().newKeyPairFromSeed(seed);
      final derived = base64Encode(
        (await key.extractPublicKey()).bytes,
      ).replaceAll('=', '');
      _checkAccount();
      if (derived != client.userDeviceKeys[userId]?.masterKey?.ed25519Key) {
        throw const QrLoginException('keys_locked');
      }
      await handle.maybeCacheAll();
      if (!encryption.crossSigning.isSelfSigned) {
        await encryption.crossSigning.selfSign(openSsss: handle);
      }
      _checkAccount();
      _masterKey = master;
    } finally {
      handle?.privateKey?.fillRange(0, handle.privateKey!.length, 0);
      if (handle != null) handle.privateKey = null;
    }
  }

  @override
  void clearSecrets() {
    _masterKey = null;
    _cleared = true;
  }

  @override
  Future<bool> deviceExists(String deviceId) async {
    _checkAccount();
    try {
      final device = await client.getDevice(deviceId);
      return device.deviceId == deviceId;
    } on MatrixException catch (error) {
      if (error.errcode == 'M_NOT_FOUND') return false;
      rethrow;
    }
  }

  @override
  Future<Map<String, Object?>> exportSecrets() async {
    await ensureSecretsAvailable();
    final encryption = client.encryption!;
    final signing = <String, Object?>{};
    final public = client.userDeviceKeys[userId];
    final entries = {
      'master_key': (
        EventTypes.CrossSigningMasterKey,
        public?.masterKey?.ed25519Key,
      ),
      'self_signing_key': (
        EventTypes.CrossSigningSelfSigning,
        public?.selfSigningKey?.ed25519Key,
      ),
      'user_signing_key': (
        EventTypes.CrossSigningUserSigning,
        public?.userSigningKey?.ed25519Key,
      ),
    };
    for (final entry in entries.entries) {
      final value = entry.key == 'master_key'
          ? _masterKey
          : await encryption.ssss.getCached(entry.value.$1);
      if (value == null) throw const QrLoginException('keys_locked');
      final seed = base64Decode(base64.normalize(value));
      if (seed.length != 32) throw const QrLoginException('keys_locked');
      final key = await Ed25519().newKeyPairFromSeed(seed);
      final derived = base64Encode(
        (await key.extractPublicKey()).bytes,
      ).replaceAll('=', '');
      if (derived != entry.value.$2) {
        throw const QrLoginException('keys_locked');
      }
      signing[entry.key] = base64Encode(seed).replaceAll('=', '');
    }
    final result = <String, Object?>{'cross_signing': signing};
    final backup = await encryption.ssss.getCached(EventTypes.MegolmBackup);
    if (backup != null) {
      try {
        final info = await client.getRoomKeysVersionCurrent();
        final key = await X25519().newKeyPairFromSeed(
          base64Decode(base64.normalize(backup)),
        );
        final derived = base64Encode(
          (await key.extractPublicKey()).bytes,
        ).replaceAll('=', '');
        if (info.algorithm.name == 'm.megolm_backup.v1.curve25519-aes-sha2' &&
            derived == info.authData['public_key']) {
          result['backup'] = {
            'algorithm': info.algorithm.name,
            'key': backup.replaceAll('=', ''),
            'backup_version': info.version,
          };
        }
      } on MatrixException catch (error) {
        if (error.errcode != 'M_NOT_FOUND') rethrow;
      }
    }
    _checkAccount();
    return result;
  }
}
