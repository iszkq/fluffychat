// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:fluffychat/utils/crypto_identity_watcher.dart';
import 'package:fluffychat/utils/error_reporter.dart';
import 'package:fluffychat/utils/localized_exception_extension.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

import 'bootstrap_state.dart';

class BootstrapViewModel extends ValueNotifier<BootstrapViewModelState> {
  final Client client;
  final bool reset;
  CryptoIdentityWatcher? _identityWatcher;
  Timer? _secretsTimeout;
  bool _disposed = false;
  bool _startingVerification = false;
  bool _refreshingDevices = false;
  KeyVerification? _completedVerification;
  Object? _identityError;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  final TextEditingController enterPassphraseOrRecovController =
      TextEditingController();
  final TextEditingController newPassphraseController = TextEditingController();
  final TextEditingController repeatPassphraseController =
      TextEditingController();
  final ScrollController devicesScrollController = ScrollController();

  BootstrapViewModel({required this.client, required this.reset})
    : super(BootstrapViewModelState()..reset = reset) {
    _init();
  }

  @override
  void dispose() {
    _disposed = true;
    _identityWatcher?.dispose();
    _secretsTimeout?.cancel();
    _cancelKeyVerification();
    enterPassphraseOrRecovController.dispose();
    newPassphraseController.dispose();
    repeatPassphraseController.dispose();
    devicesScrollController.dispose();
    super.dispose();
  }

  void _checkCanCreatePassphrase([_]) {
    final passphrase = newPassphraseController.text;
    value.newPassphraseEqualsRepeatPassphrase =
        passphrase.isNotEmpty && passphrase == repeatPassphraseController.text;
    value.newPassphraseLongEnough = passphrase.length >= 12;
    value.newPassphraseUpperAndLowerCase =
        passphrase.contains(RegExp(r'[A-Z]')) &&
        passphrase.contains(RegExp(r'[a-z]'));
    value.newPassphraseSpecialCharacters = passphrase.contains(
      RegExp(r'[!@#$%^&*(),.?":{}|<>]'),
    );
    value.newPassphraseNumbers = passphrase.contains(RegExp(r'\d'));
    _notify();
  }

  Future<void> retryKeyVerification([DeviceKeys? device]) async {
    if (_startingVerification || _disposed) return;
    _startingVerification = true;
    _cancelKeyVerification();
    _secretsTimeout?.cancel();
    value.waitingForSecrets = false;
    value.noSecretsreceived = false;
    value.recoveryError = null;
    _notify();
    try {
      await client.updateUserDeviceKeys().timeout(const Duration(seconds: 20));
      if (_disposed) return;
      final devices = client.userDeviceKeys[client.userID!];
      if (devices == null) {
        throw StateError('No devices available for verification');
      }
      final request = device == null
          ? await devices.startVerification()
          : await device.startVerification();
      if (_disposed) {
        unawaited(request.cancel());
        return;
      }
      value.keyVerification = request;
      request.onUpdate = () {
        if (identical(value.keyVerification, request)) {
          unawaited(_onKeyVerificationUpdate());
        }
      };
      await _onKeyVerificationUpdate();
    } catch (error) {
      if (!_disposed) value.recoveryError = error;
    } finally {
      _startingVerification = false;
      _notify();
    }
  }

  Future<void> refreshConnectedDevices() async {
    if (_refreshingDevices || _disposed) return;
    _refreshingDevices = true;
    try {
      await client.updateUserDeviceKeys().timeout(const Duration(seconds: 20));
      if (_disposed) return;
      final devices =
          client.userDeviceKeys[client.userID!]?.deviceKeys.values
              .where(
                (device) =>
                    device.deviceId != client.deviceID && !device.blocked,
              )
              .toList() ??
          <DeviceKeys>[];
      value.connectedDevices = devices;
      value.recoveryError = null;
      _notify();
      // Preserve automatic requests to signed devices. Other own devices remain
      // visible and can be selected for explicit SAS; listing never trusts them.
      if (value.keyVerification == null &&
          devices.any(
            (device) =>
                device.hasValidSignatureChain(verifiedByTheirMasterKey: true),
          )) {
        await retryKeyVerification();
      }
    } catch (error) {
      if (!_disposed) {
        value.recoveryError = error;
        _notify();
      }
    } finally {
      _refreshingDevices = false;
    }
  }

  void _init() {
    newPassphraseController.addListener(_checkCanCreatePassphrase);
    repeatPassphraseController.addListener(_checkCanCreatePassphrase);
    enterPassphraseOrRecovController.addListener(
      _passphraseOrRecoveryKeyEntered,
    );
    _identityWatcher = CryptoIdentityWatcher(
      read: client.getCryptoIdentityState,
      events: [
        client.onSync.stream,
        if (client.encryption != null)
          client.encryption!.ssss.onSecretStored.stream,
      ],
      onState: (state) {
        if (_disposed) return;
        value.cryptoIdentityState = state;
        if (identical(value.recoveryError, _identityError)) {
          value.recoveryError = null;
        }
        _identityError = null;
        if (state.connected) {
          _secretsTimeout?.cancel();
          value.waitingForSecrets = false;
          value.noSecretsreceived = false;
        }
        _notify();
        if (state.initialized &&
            !state.connected &&
            !value.reset &&
            value.connectedDevices == null) {
          unawaited(refreshConnectedDevices());
        }
      },
      onError: (error) {
        _identityError = error;
        value.recoveryError = error;
        _notify();
      },
    )..start();
    if (supportsSecureStorage) {
      unawaited(_readRecoveryKey());
    }
  }

  Future<void> refreshCryptoIdentity() async {
    await _identityWatcher?.refresh();
  }

  Future<void> _readRecoveryKey() async {
    try {
      final key = await const FlutterSecureStorage().read(
        key: _secureStorageKey,
      );
      if (!_disposed && key != null) {
        enterPassphraseOrRecovController.text = key;
      }
    } catch (error, stack) {
      Logs().e('Unable to read key from secure storage', error, stack);
    }
  }

  void _passphraseOrRecoveryKeyEntered() {
    final passphraseOrRecoveryKeyEntered =
        enterPassphraseOrRecovController.text.isNotEmpty;
    if (value.passphraseOrRecoveryKeyEntered !=
        passphraseOrRecoveryKeyEntered) {
      value.passphraseOrRecoveryKeyEntered = passphraseOrRecoveryKeyEntered;
      _notify();
    }
  }

  Future<void> _onKeyVerificationUpdate() async {
    if (_disposed) return;
    if (value.keyVerification?.state == KeyVerificationState.done &&
        !identical(_completedVerification, value.keyVerification) &&
        value.cryptoIdentityState?.connected != true) {
      _completedVerification = value.keyVerification;
      value.waitingForSecrets = true;
      value.noSecretsreceived = false;
      _secretsTimeout?.cancel();
      _secretsTimeout = Timer(const Duration(seconds: 30), () {
        if (_disposed || value.cryptoIdentityState?.connected == true) return;
        value.waitingForSecrets = false;
        value.noSecretsreceived = true;
        _notify();
      });
    }
    _notify();
    await _identityWatcher?.refresh();
  }

  Future<void> setOrSkipPassphrase(
    String? passphrase,
    BuildContext context,
  ) async {
    value.isLoading = true;
    _notify();
    try {
      final state = await client.getCryptoIdentityState();
      if (state.connected) {
        Logs().i('Download the key backup...');
        await client.encryption!.keyManager.loadAllKeys();
      }

      Logs().i('Init crypto identity...');
      value.recoveryKey = await client.initCryptoIdentity(
        passphrase: passphrase,
      );

      if (state.connected) {
        Logs().i('Mark all megolm sessions as needing upload...');
        await client.database.markInboundGroupSessionsAsNeedingUpload();
      }
    } catch (e, s) {
      if (!context.mounted) return;
      ErrorReporter(
        context,
        'Unable to init crypto identity',
      ).onErrorCallback(e, s);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      value.isLoading = false;
    }
    _notify();
  }

  void _cancelKeyVerification() {
    final keyVerification = value.keyVerification;
    value.keyVerification = null;
    if (keyVerification != null) keyVerification.onUpdate = null;
    if (keyVerification != null &&
        keyVerification.state != KeyVerificationState.done &&
        keyVerification.state != KeyVerificationState.error) {
      keyVerification.cancel();
    }
  }

  bool get supportsSecureStorage =>
      PlatformInfos.isMobile || PlatformInfos.isDesktop;

  Future<void> unlock(BuildContext context) async {
    final key = enterPassphraseOrRecovController.text.trim();
    if (key.isEmpty) return;

    _cancelKeyVerification();

    value.unlockWithError = null;
    value.isLoading = true;
    _notify();
    try {
      await client.restoreCryptoIdentity(key);
      if (_disposed) return;
      value.isLoading = false;
      value.cryptoIdentityState = await client.getCryptoIdentityState();
      _notify();
      return;
    } catch (e, s) {
      if (e is! InvalidPassphraseException) {
        const errorMessage = 'Unexpected error on unlock passphrase';
        if (context.mounted) {
          ErrorReporter(context, errorMessage).onErrorCallback(e, s);
        } else {
          Logs().wtf(errorMessage, e, s);
        }
      }
      value.isLoading = false;
      value.unlockWithError = e;
      _notify();
      if (supportsSecureStorage) {
        await FlutterSecureStorage().delete(key: _secureStorageKey);
      }
      return;
    }
  }

  void goToRoomsPageAfterSuccess(BuildContext context) {
    for (final room in client.rooms) {
      final lastEvent = room.lastEvent;
      if (lastEvent == null ||
          lastEvent.messageType != MessageTypes.BadEncrypted ||
          lastEvent.content['can_request_session'] != true) {
        continue;
      }
      final sessionId = lastEvent.content.tryGet<String>('session_id');
      final senderKey = lastEvent.content.tryGet<String>('sender_key');
      if (sessionId != null && senderKey != null) {
        client.encryption?.keyManager.maybeAutoRequest(
          room.id,
          sessionId,
          senderKey,
        );
      }
    }
    if (!_disposed && context.mounted) context.go('/rooms');
  }

  void toggleObscureText() {
    value.obscureText = !value.obscureText;
    _notify();
  }

  void startResetAccount() {
    value.reset = true;
    _notify();
  }

  String get _secureStorageKey => 'ssss_recovery_key_${client.userID}';

  Future<void> openRecoveryKeyFile(BuildContext context) async {
    final result = await FilePicker.pickFile(
      allowedExtensions: ['txt'],
      type: FileType.custom,
    );
    final file = result?.xFile;
    if (file == null) return;
    try {
      final key = await file.readAsString();
      enterPassphraseOrRecovController.text = key;
    } catch (e, s) {
      Logs().d('Unable to read recovery key file', e, s);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      }
    }
    if (context.mounted) await unlock(context);
  }

  Future<void> toggleRecoveryKeyDownloaded(
    bool? downloaded,
    BuildContext context,
  ) async {
    final path = await FilePicker.saveFile(
      fileName:
          'FluffyChat-Recovery-Key-${DateTime.now().toIso8601String()}.txt',
      bytes: Uint8List.fromList(value.recoveryKey!.codeUnits),
    );
    if (path == null) return;
    value.recoveryKeyDownloaded = downloaded == true;
    _notify();
  }

  Future<void> toggleRecoveryKeyStoredInSecureStorage(bool? stored) async {
    if (stored == true) {
      await FlutterSecureStorage().write(
        key: _secureStorageKey,
        value: value.recoveryKey,
      );
    } else {
      await FlutterSecureStorage().delete(key: _secureStorageKey);
    }
    value.recoveryKeyStoredInSecureStorage = stored == true;
    _notify();
  }
}
