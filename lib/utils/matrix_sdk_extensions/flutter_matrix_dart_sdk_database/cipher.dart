// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';
import 'dart:math';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/client_manager.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:matrix/matrix.dart';

const _passwordStorageKey = 'database_password';
const _sharedIosOptions = IOSOptions(groupId: 'group.im.fluffychat.app');
const _privateIosOptions = IOSOptions();

Future<String?> getDatabaseCipher() async {
  try {
    return await _readOrCreateDatabaseCipher(
      _sharedIosOptions,
      migrateFromPrivateStorage: PlatformInfos.isIOS,
    );
  } catch (sharedStorageError, sharedStorageStackTrace) {
    if (PlatformInfos.isIOS) {
      Logs().w(
        'Shared iOS Keychain access is unavailable. Falling back to the app Keychain.',
        sharedStorageError,
        sharedStorageStackTrace,
      );
      try {
        return await _readOrCreateDatabaseCipher(_privateIosOptions);
      } catch (privateStorageError, privateStorageStackTrace) {
        return _handleCipherError(
          privateStorageError,
          privateStorageStackTrace,
          _privateIosOptions,
        );
      }
    }
    return _handleCipherError(
      sharedStorageError,
      sharedStorageStackTrace,
      _sharedIosOptions,
    );
  }
}

Future<String> _readOrCreateDatabaseCipher(
  IOSOptions iosOptions, {
  bool migrateFromPrivateStorage = false,
}) async {
  final secureStorage = FlutterSecureStorage(iOptions: iosOptions);
  var password = await secureStorage.read(
    key: _passwordStorageKey,
    iOptions: iosOptions,
  );
  if (password != null) return password;

  if (migrateFromPrivateStorage) {
    final privateStorage = FlutterSecureStorage(iOptions: _privateIosOptions);
    final privatePassword = await privateStorage.read(
      key: _passwordStorageKey,
      iOptions: _privateIosOptions,
    );
    if (privatePassword != null) {
      Logs().i('Migrating database key to the shared iOS Keychain...');
      await secureStorage.write(
        key: _passwordStorageKey,
        value: privatePassword,
        iOptions: iosOptions,
      );
      await privateStorage.delete(
        key: _passwordStorageKey,
        iOptions: _privateIosOptions,
      );
      return privatePassword;
    }
  }

  final rng = Random.secure();
  final list = Uint8List(32);
  list.setAll(0, Iterable.generate(list.length, (i) => rng.nextInt(256)));
  final newPassword = base64UrlEncode(list);
  await secureStorage.write(
    key: _passwordStorageKey,
    value: newPassword,
    iOptions: iosOptions,
  );

  // Work around platforms where a successful write is not immediately
  // readable. Treat that as unavailable secure storage instead of using a
  // database key that cannot be recovered on the next launch.
  password = await secureStorage.read(
    key: _passwordStorageKey,
    iOptions: iosOptions,
  );
  if (password == null) throw MissingPluginException();
  return password;
}

String? _handleCipherError(
  Object exception,
  StackTrace stackTrace,
  IOSOptions iosOptions,
) {
  FlutterSecureStorage(
    iOptions: iosOptions,
  ).delete(key: _passwordStorageKey, iOptions: iosOptions).catchError((_) {});
  if (exception is MissingPluginException) {
    Logs().w(
      'Database encryption is not supported on this platform',
      exception,
    );
  } else {
    Logs().w('Unable to init database encryption', exception, stackTrace);
  }
  _sendNoEncryptionWarning(exception);
  return null;
}

Future<void> _sendNoEncryptionWarning(Object exception) async {
  final isStored = AppSettings.noEncryptionWarningShown.value;

  if (isStored == true) return;

  final l10n = await lookupL10n(PlatformDispatcher.instance.locale);
  ClientManager.sendInitNotification(
    l10n.noDatabaseEncryption,
    exception.toString(),
  );

  await AppSettings.noEncryptionWarningShown.setItem(true);
}
