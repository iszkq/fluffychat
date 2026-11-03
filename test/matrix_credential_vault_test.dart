// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:fluffychat/utils/qr_login/credential_vault.dart';
import 'package:fluffychat/utils/qr_login/matrix_credential_vault.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:test/test.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Secrets extends SSSS {
  String? seed;
  _Secrets(super.encryption);
  @override
  Future<String?> getCached(String type) async =>
      type == EventTypes.CrossSigningSelfSigning ? seed : null;
}

class _Client extends Client {
  final records = <String, Map<String, Object?>>{};
  final writes = <Map<String, Object?>>[];
  Completer<void>? pauseWrite;
  String currentUser = '@alice:example.org';
  late final Encryption testEncryption;
  late final _Secrets secrets;
  _Client() : super('credential-test', database: _UnusedDatabase()) {
    homeserver = Uri.parse('https://matrix.example.org');
    testEncryption = Encryption(client: this);
    secrets = _Secrets(testEncryption);
    testEncryption.ssss = secrets;
  }
  @override
  String get userID => currentUser;
  @override
  String get deviceID => 'PHONE';
  @override
  bool isLogged() => true;
  @override
  Encryption get encryption => testEncryption;

  @override
  Future<void> setAccountData(
    String userId,
    String type,
    Map<String, Object?> content,
  ) async {
    expect(userId, '@alice:example.org');
    expect(type, loginCredentialsAccountDataType);
    await pauseWrite?.future;
    records[type] = Map.of(content);
    writes.add(Map.of(content));
  }

  @override
  Future<Map<String, Object?>> getAccountData(
    String userId,
    String type,
  ) async => Map.of(records[type] ?? {});

  Future<void> unlock() async {
    final seed = List<int>.filled(32, 7);
    final pair = await Ed25519().newKeyPairFromSeed(seed);
    final public = base64Encode(
      (await pair.extractPublicKey()).bytes,
    ).replaceAll('=', '');
    userDeviceKeys[userID] = DeviceKeysList(
      userID,
      this,
      crossSigningKeys: {
        public: CrossSigningKey.fromJson({
          'user_id': userID,
          'usage': ['self_signing'],
          'keys': {'ed25519:$public': public},
        }, this),
      },
    );
    secrets.seed = base64Encode(seed);
  }

  Future<void> stopPending() async {
    onLoginStateChanged.add(LoginState.loggedOut);
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'successful password login waits for encryption setup and uploads ciphertext',
    () async {
      final client = _Client();
      addTearDown(client.stopPending);
      MatrixCredentialVault.captureAfterLogin(client, 'synthetic-password');
      await Future<void>.delayed(Duration.zero);
      expect(client.writes, isEmpty);
      await client.unlock();
      expect(
        await MatrixCredentialVault(client).loadPassword(),
        'synthetic-password',
      );
      expect(client.writes, hasLength(1));
      expect(jsonEncode(client.writes), isNot(contains('synthetic-password')));
      expect(
        await MatrixCredentialVault(client).loadPassword(),
        'synthetic-password',
      );
    },
  );

  test(
    'password change during an upload leaves the latest password on the server',
    () async {
      final client = _Client();
      addTearDown(client.stopPending);
      await client.unlock();
      client.pauseWrite = Completer<void>();
      MatrixCredentialVault.captureAfterLogin(client, 'old-synthetic');
      await Future<void>.delayed(Duration.zero);
      MatrixCredentialVault.captureAfterLogin(client, 'new-synthetic');
      client.pauseWrite!.complete();
      expect(
        await MatrixCredentialVault(client).loadPassword(),
        'new-synthetic',
      );
      expect(client.writes, hasLength(2));
    },
  );

  test(
    'logout discards a pending password instead of uploading it on later unlock',
    () async {
      final client = _Client();
      MatrixCredentialVault.captureAfterLogin(client, 'synthetic-password');
      await client.stopPending();
      await client.unlock();
      await expectLater(
        MatrixCredentialVault(client).loadPassword(),
        throwsA(isA<CredentialVaultException>()),
      );
      expect(client.writes, isEmpty);
    },
  );
}
