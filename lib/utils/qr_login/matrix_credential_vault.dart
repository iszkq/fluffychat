// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:matrix/matrix.dart';

import 'credential_vault.dart';

class MatrixCredentialVault {
  static final _pending = Expando<_PendingPasswordUpload>();
  final Client client;
  final String _userId;
  final String _deviceId;
  final String _homeserver;

  MatrixCredentialVault(this.client)
    : _userId = client.userID!,
      _deviceId = client.deviceID!,
      _homeserver = client.homeserver!.toString().replaceFirst(
        RegExp(r'/+$'),
        '',
      );

  void _checkAccount() {
    if (!client.isLogged() ||
        client.userID != _userId ||
        client.deviceID != _deviceId ||
        client.homeserver!.toString().replaceFirst(RegExp(r'/+$'), '') !=
            _homeserver) {
      throw const CredentialVaultException('account_changed');
    }
  }

  Future<CredentialWrappingKey?> _wrappingKey() async {
    _checkAccount();
    await client.accountDataLoading;
    await client.userDeviceKeysLoading;
    final seed = await client.encryption?.ssss.getCached(
      EventTypes.CrossSigningSelfSigning,
    );
    _checkAccount();
    final expected = client.userDeviceKeys[_userId]?.selfSigningKey?.ed25519Key;
    if (seed == null || expected == null) return null;
    final bytes = Uint8List.fromList(base64Decode(base64.normalize(seed)));
    try {
      if (bytes.length != 32) return null;
      final pair = await Ed25519().newKeyPairFromSeed(bytes);
      final actual = base64Encode(
        (await pair.extractPublicKey()).bytes,
      ).replaceAll('=', '');
      if (actual != expected) return null;
      return CredentialWrappingKey(expected, Uint8List.fromList(bytes));
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  late final _vault = CredentialVault(
    userId: _userId,
    homeserver: _homeserver,
    loadWrappingKey: _wrappingKey,
    readAccountData: () async {
      _checkAccount();
      try {
        final content = await client
            .getAccountData(_userId, loginCredentialsAccountDataType)
            .timeout(const Duration(seconds: 20));
        _checkAccount();
        return content;
      } on MatrixException catch (error) {
        if (error.errcode == 'M_NOT_FOUND') return <String, Object?>{};
        if ([
          'M_UNKNOWN_TOKEN',
          'M_MISSING_TOKEN',
          'M_FORBIDDEN',
        ].contains(error.errcode)) {
          throw const CredentialVaultException('session_expired');
        }
        throw const CredentialVaultException('credentials_read_failed');
      } on TimeoutException {
        throw const CredentialVaultException('credentials_timeout');
      } on CredentialVaultException {
        rethrow;
      } catch (_) {
        throw const CredentialVaultException('credentials_read_failed');
      }
    },
    writeAccountData: (content) async {
      _checkAccount();
      await client
          .setAccountData(_userId, loginCredentialsAccountDataType, content)
          .timeout(const Duration(seconds: 20));
      _checkAccount();
    },
  );

  Future<String> loadPassword() async {
    final pending = _pending[client];
    await pending?.flush();
    if (pending != null && !pending._cancelled && pending.failure != null) {
      throw CredentialVaultException(pending.failure!);
    }
    return _vault.load();
  }

  /// Called only after successful password authentication. Wait in memory for
  /// initial backup setup / verification; never write the plaintext locally.
  static void captureAfterLogin(Client client, String password) {
    if (!client.isLogged() || password.isEmpty) return;
    final previous = _pending[client];
    if (previous != null && previous.matchesAccount) {
      previous.replace(password);
      return;
    }
    previous?.cancel();
    final pending = _PendingPasswordUpload(
      MatrixCredentialVault(client),
      password,
    );
    _pending[client] = pending;
    pending.start();
  }
}

class _PendingPasswordUpload {
  final MatrixCredentialVault vault;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  String? _password;
  int _revision = 0;
  Timer? _expiry;
  Timer? _retry;
  Future<void>? _saving;
  bool _cancelled = false;
  String? failure;

  _PendingPasswordUpload(this.vault, this._password);

  bool get matchesAccount {
    try {
      vault._checkAccount();
      return !_cancelled;
    } catch (_) {
      return false;
    }
  }

  void start() {
    _expiry = Timer(const Duration(minutes: 10), cancel);
    _subscriptions.add(
      vault.client.onSync.stream.listen((_) => unawaited(flush())),
    );
    _subscriptions.add(
      vault.client.onLoginStateChanged.stream.listen((state) {
        if (state == LoginState.loggedOut) cancel();
      }),
    );
    final stored = vault.client.encryption?.ssss.onSecretStored.stream;
    if (stored != null) {
      _subscriptions.add(stored.listen((_) => unawaited(flush())));
    }
    _retry = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(flush());
    });
    unawaited(flush());
  }

  void replace(String password) {
    _password = password;
    _revision++;
    unawaited(flush());
  }

  Future<void> flush() async {
    if (_saving != null) return _saving;
    if (_cancelled || _password == null) return;
    final task = _saving = _saveLatest();
    try {
      await task;
    } finally {
      _saving = null;
    }
  }

  Future<void> _saveLatest() async {
    int revision;
    do {
      revision = _revision;
      await _save();
    } while (!_cancelled && revision != _revision);
  }

  Future<void> _save() async {
    final revision = _revision;
    try {
      vault._checkAccount();
      await vault._vault.save(_password!);
      failure = null;
      if (revision == _revision) cancel();
    } on CredentialVaultException catch (error) {
      failure = error.reason;
      if (error.reason == 'account_changed') cancel();
      // Locked keys are expected until the user completes encryption setup.
    } catch (_) {
      failure = 'credentials_upload_failed';
      // Retry transient failures without logging the password or request body.
    }
  }

  void cancel() {
    _cancelled = true;
    _password = null;
    _expiry?.cancel();
    _retry?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    if (identical(MatrixCredentialVault._pending[vault.client], this)) {
      MatrixCredentialVault._pending[vault.client] = null;
    }
  }
}
