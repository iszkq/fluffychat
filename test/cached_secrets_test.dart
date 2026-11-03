// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:fluffychat/utils/qr_login/matrix_qr_login_account.dart';
import 'package:fluffychat/utils/qr_login/msc4108_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/encryption/cross_signing.dart';
import 'package:matrix/matrix.dart';

class _Database implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Signing extends CrossSigning {
  bool trusted = true;
  _Signing(super.encryption);
  @override
  bool get isSelfSigned => trusted;
}

class _Secrets extends SSSS {
  final values = <String, String>{};
  _Secrets(super.encryption);
  @override
  Future<String?> getCached(String name) async => values[name];
}

class _Encryption extends Encryption {
  late final _Signing signing;
  _Encryption(Client client) : super(client: client) {
    signing = _Signing(this);
  }
  @override
  CrossSigning get crossSigning => signing;
}

class _Client extends Client {
  late final Encryption crypto;
  late final _Secrets secrets;
  late final _Signing signing;
  String backupPublic = '';
  _Client() : super('cached-secrets-test', database: _Database()) {
    crypto = _Encryption(this);
    secrets = _Secrets(crypto);
    signing = (crypto as _Encryption).signing;
    crypto.ssss = secrets;
  }
  @override
  String get userID => '@alice:example.org';
  @override
  String get deviceID => 'PHONE';
  @override
  bool isLogged() => true;
  @override
  Encryption get encryption => crypto;
  @override
  Future<GetRoomKeysVersionCurrentResponse> getRoomKeysVersionCurrent() async =>
      GetRoomKeysVersionCurrentResponse.fromJson({
        'algorithm': 'm.megolm_backup.v1.curve25519-aes-sha2',
        'auth_data': {'public_key': backupPublic},
        'count': 0,
        'etag': '0',
        'version': '1',
      });
  Future<void> setup() async {
    final keys = <String, CrossSigningKey>{};
    for (final item in [
      (EventTypes.CrossSigningMasterKey, 'master', 1),
      (EventTypes.CrossSigningSelfSigning, 'self_signing', 2),
      (EventTypes.CrossSigningUserSigning, 'user_signing', 3),
    ]) {
      final seed = List<int>.filled(32, item.$3);
      final pair = await Ed25519().newKeyPairFromSeed(seed);
      final public = base64Encode(
        (await pair.extractPublicKey()).bytes,
      ).replaceAll('=', '');
      keys[public] = CrossSigningKey.fromJson({
        'user_id': userID,
        'usage': [item.$2],
        'keys': {'ed25519:$public': public},
      }, this);
      if (item.$2 != 'master') secrets.values[item.$1] = base64Encode(seed);
    }
    userDeviceKeys[userID] = DeviceKeysList(
      userID,
      this,
      crossSigningKeys: keys,
    );
    final seed = List<int>.filled(32, 4);
    secrets.values[EventTypes.MegolmBackup] = base64Encode(seed);
    final pair = await X25519().newKeyPairFromSeed(seed);
    backupPublic = base64Encode(
      (await pair.extractPublicKey()).bytes,
    ).replaceAll('=', '');
  }
}

void main() {
  test(
    'verified phone exports validated cached signing and backup keys without a master seed, recovery input or storage',
    () async {
      final client = _Client();
      await client.setup();
      expect(
        await client.secrets.getCached(EventTypes.CrossSigningMasterKey),
        isNull,
      );
      final bundle = await MatrixQrLoginAccount(
        client,
      ).exportCachedSecrets('PC');
      expect(bundle['device_id'], 'PC');
      expect(
        bundle['master_key'],
        client.userDeviceKeys[client.userID]!.masterKey!.ed25519Key,
      );
      expect(
        (bundle['self_signing_key'] as Map)['private_key'],
        client.secrets.values[EventTypes.CrossSigningSelfSigning]!.replaceAll(
          '=',
          '',
        ),
      );
      expect((bundle['backup'] as Map)['backup_version'], '1');
      expect(bundle.containsKey('master_private_key'), isFalse);
    },
  );
  test(
    'phone with locked signing secrets cannot silently authorize decryption',
    () async {
      final client = _Client();
      await client.setup();
      client.secrets.values.remove(EventTypes.CrossSigningSelfSigning);
      await expectLater(
        MatrixQrLoginAccount(client).exportCachedSecrets('PC'),
        throwsA(isA<QrLoginException>()),
      );
    },
  );
  test('substituted cached private key is rejected before sharing', () async {
    final client = _Client();
    await client.setup();
    client.secrets.values[EventTypes.CrossSigningSelfSigning] = base64Encode(
      List.filled(32, 9),
    );
    await expectLater(
      MatrixQrLoginAccount(client).exportCachedSecrets('PC'),
      throwsA(isA<QrLoginException>()),
    );
  });
  test('unverified phone cannot grant QR identity trust', () async {
    final client = _Client();
    await client.setup();
    client.signing.trusted = false;
    await expectLater(
      MatrixQrLoginAccount(client).exportCachedSecrets('PC'),
      throwsA(isA<QrLoginException>()),
    );
  });
  test('mismatched backup cannot be reported as a usable backup', () async {
    final client = _Client();
    await client.setup();
    client.backupPublic = 'wrong';
    await expectLater(
      MatrixQrLoginAccount(client).exportCachedSecrets('PC'),
      throwsA(isA<QrLoginException>()),
    );
  });
}
