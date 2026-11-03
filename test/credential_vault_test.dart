// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:typed_data';

import 'package:fluffychat/utils/qr_login/credential_vault.dart';
import 'package:test/test.dart';

void main() {
  late Map<String, Object?> server;
  late List<Uint8List> copies;
  CredentialVault vault({String user = '@alice:example.org', int seed = 1}) =>
      CredentialVault(
        userId: user,
        homeserver: 'https://matrix.example.org',
        loadWrappingKey: () async {
          final bytes = Uint8List.fromList(List.filled(32, seed));
          copies.add(bytes);
          return CredentialWrappingKey('self-signing-public-key', bytes);
        },
        readAccountData: () async => Map.of(server),
        writeAccountData: (content) async => server = content,
      );

  setUp(() {
    server = {};
    copies = [];
  });

  test(
    'server receives ciphertext and a fresh client can recover the password',
    () async {
      await vault().save('密码 synthetic-password');
      expect(jsonEncode(server), isNot(contains('synthetic-password')));
      expect(server.containsKey('password'), isFalse);
      expect(await vault().load(), '密码 synthetic-password');
      expect(copies.every((bytes) => bytes.every((byte) => byte == 0)), isTrue);
    },
  );

  test(
    'password changes replace the server record, without caching old plaintext',
    () async {
      await vault().save('old-synthetic');
      final old = jsonEncode(server);
      await vault().save('new-synthetic');
      expect(jsonEncode(server), isNot(old));
      expect(await vault().load(), 'new-synthetic');
      expect(jsonEncode(server), isNot(contains('old-synthetic')));
    },
  );

  test(
    'ciphertext authentication rejects edits, another account, and a wrong key',
    () async {
      await vault().save('synthetic');
      final original = Map<String, Object?>.of(server);
      await expectLater(
        vault(user: '@bob:example.org').load(),
        throwsA(isA<CredentialVaultException>()),
      );
      await expectLater(
        vault(seed: 2).load(),
        throwsA(isA<CredentialVaultException>()),
      );
      final cipher = base64Decode(server['ciphertext'] as String);
      cipher[0] ^= 1;
      server['ciphertext'] = base64Encode(cipher);
      await expectLater(
        vault().load(),
        throwsA(isA<CredentialVaultException>()),
      );
      server = original;
      server['key_id'] = 'replaced-cross-signing-key';
      await expectLater(
        vault().load(),
        throwsA(isA<CredentialVaultException>()),
      );
    },
  );

  test(
    'missing records and locked encryption never save an unencrypted fallback',
    () async {
      await expectLater(
        vault().load(),
        throwsA(isA<CredentialVaultException>()),
      );
      final locked = CredentialVault(
        userId: '@alice:example.org',
        homeserver: 'https://matrix.example.org',
        loadWrappingKey: () async => null,
        readAccountData: () async => server,
        writeAccountData: (_) async => fail('Must not upload plaintext'),
      );
      await expectLater(
        locked.save('synthetic'),
        throwsA(isA<CredentialVaultException>()),
      );
      expect(server, isEmpty);
    },
  );
}
