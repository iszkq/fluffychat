// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'msc4108_channel.dart';
import 'qr_login_payload.dart';

class QrLoginAuthMetadata {
  final Uri issuer;
  final bool supportsDeviceGrant;
  const QrLoginAuthMetadata(this.issuer, {required this.supportsDeviceGrant});
}

abstract class QrLoginAccount {
  String get userId;
  String? get deviceId => null;
  bool get supportsVerificationHandoff => false;
  Future<QrLoginAuthMetadata> authMetadata();
  Future<void> ensureSecretsAvailable();
  Future<bool> deviceExists(String deviceId);
  Future<Map<String, Object?>> exportSecrets();

  Future<void> unlockSecrets(String recoveryKeyOrPassphrase) async {
    throw const QrLoginException('keys_locked');
  }

  void clearSecrets() {}
}

/// Existing, authenticated device's MSC4108 NewScanned state machine.
/// UI confirms the check code before opening the issuer's authorization page.
class QrLoginExistingDevice {
  final QrLoginAccount account;
  final QrLoginPayload payload;
  final Msc4108Channel channel;
  final Duration deviceWait;
  final Duration devicePollInterval;
  bool _started = false;
  bool needsDeviceVerification = false;

  QrLoginExistingDevice({
    required this.account,
    required this.payload,
    Msc4108Channel? channel,
    this.deviceWait = const Duration(seconds: 15),
    this.devicePollInterval = const Duration(seconds: 1),
  }) : channel =
           channel ?? Msc4108Channel(Msc4108Transport(payload.rendezvous));

  Future<void> run({
    required Future<bool> Function(String code) confirmCode,
    required Future<bool> Function(Uri uri, String deviceId) authorize,
    required void Function() onSharingSecrets,
    Future<bool> Function()? unlockSecrets,
  }) async {
    if (_started) throw StateError('Login already started');
    _started = true;
    try {
      final metadata = await account.authMetadata().timeout(
        const Duration(seconds: 20),
      );
      if (!metadata.supportsDeviceGrant ||
          !isSecureQrLoginUri(metadata.issuer)) {
        throw const QrLoginException('unsupported_protocol');
      }
      try {
        await account.ensureSecretsAvailable().timeout(
          const Duration(seconds: 20),
        );
      } on QrLoginException catch (error) {
        if (error.reason != 'keys_locked') rethrow;
        if (account.supportsVerificationHandoff && account.deviceId != null) {
          // This app-to-app handoff does not claim key transfer succeeded.
          // The new device must run standard Matrix SAS + Olm secret sharing.
          needsDeviceVerification = true;
        } else {
          if (unlockSecrets == null) rethrow;
          if (!await unlockSecrets()) {
            throw const QrLoginException('user_cancelled');
          }
          channel.transport.checkActive();
          await account.ensureSecretsAvailable().timeout(
            const Duration(seconds: 20),
          );
        }
      }
      await channel.connect(payload.publicKey);
      final separator = account.userId.indexOf(':');
      if (!account.userId.startsWith('@') || separator < 2) {
        throw const QrLoginException('account_changed');
      }
      await channel.send({
        'type': 'm.login.protocols',
        'protocols': ['device_authorization_grant'],
        'homeserver': account.userId.substring(separator + 1),
      });
      if (!await confirmCode(channel.checkCode)) {
        throw const QrLoginException('user_cancelled');
      }
      channel.transport.checkActive();
      final request = await channel.receive();
      if (request['type'] != 'm.login.protocol' ||
          request['protocol'] != 'device_authorization_grant') {
        throw const QrLoginException('unexpected_message_received');
      }
      final deviceId = request['device_id'];
      final grant = request['device_authorization_grant'];
      if (deviceId is! String ||
          deviceId.isEmpty ||
          deviceId.length > 255 ||
          grant is! Map<String, Object?>) {
        throw const QrLoginException('unexpected_message_received');
      }
      // Only mxchat versions explicitly advertising this extension can accept
      // a login without the complete MSC4108 secrets bundle. Preserve the
      // recovery/export path for all other Matrix clients.
      if (needsDeviceVerification &&
          request['org.mxchat.device_verification'] != 1) {
        needsDeviceVerification = false;
        if (unlockSecrets == null) throw const QrLoginException('keys_locked');
        if (!await unlockSecrets()) {
          throw const QrLoginException('user_cancelled');
        }
        channel.transport.checkActive();
        await account.ensureSecretsAvailable().timeout(
          const Duration(seconds: 20),
        );
      }
      final verification = grant['verification_uri'];
      final complete = grant['verification_uri_complete'];
      if (verification is! String ||
          (complete != null && complete is! String)) {
        throw const QrLoginException('unexpected_message_received');
      }
      final baseUri = Uri.tryParse(verification);
      final completeUri = complete is String ? Uri.tryParse(complete) : baseUri;
      // The scanned device must never be able to open a phishing authorization
      // page. Trust only the issuer discovered from our own logged-in account.
      bool trusted(Uri? uri) =>
          uri != null &&
          isSecureQrLoginUri(uri) &&
          uri.origin == metadata.issuer.origin;
      if (!trusted(baseUri) ||
          !trusted(completeUri) ||
          completeUri!.path != baseUri!.path) {
        throw const QrLoginException('authorization_uri_mismatch');
      }
      if (await account
          .deviceExists(deviceId)
          .timeout(const Duration(seconds: 20))) {
        throw const QrLoginException('device_already_exists');
      }
      if (!await authorize(completeUri, deviceId)) {
        throw const QrLoginException('user_cancelled');
      }
      await channel.send({'type': 'm.login.protocol_accepted'});
      final outcome = await channel.receive();
      if (outcome['type'] == 'm.login.declined') {
        throw const QrLoginException('user_cancelled');
      }
      if (outcome['type'] != 'm.login.success') {
        throw const QrLoginException('unexpected_message_received');
      }
      // The device must now exist under THIS account. A browser session signed
      // into another account must never receive this account's secrets.
      final deadline = DateTime.now().add(deviceWait);
      while (!await account
          .deviceExists(deviceId)
          .timeout(const Duration(seconds: 20))) {
        channel.transport.checkActive();
        if (DateTime.now().isAfter(deadline)) {
          throw const QrLoginException('device_not_found');
        }
        await Future<void>.delayed(devicePollInterval);
      }
      channel.transport.checkActive();
      if (needsDeviceVerification) {
        await channel.send({
          'type': 'm.login.secrets',
          'org.mxchat.device_verification': {
            'user_id': account.userId,
            'device_id': account.deviceId,
          },
        });
        return;
      }
      onSharingSecrets();
      final secrets = await account.exportSecrets().timeout(
        const Duration(seconds: 20),
      );
      channel.transport.checkActive();
      await channel.send({'type': 'm.login.secrets', ...secrets});
      // New device owns rendezvous cleanup. Deleting now could race its GET.
    } catch (error) {
      if (!channel.transport.closed) {
        try {
          await channel
              .send({
                'type': 'm.login.failure',
                'reason': error is QrLoginException ? error.reason : 'unknown',
              })
              .timeout(const Duration(seconds: 2));
        } catch (_) {
          /* No established channel or peer already gone. */
        }
      }
      rethrow;
    } finally {
      channel.close();
      account.clearSecrets();
    }
  }

  void cancel() {
    channel.close();
    account.clearSecrets();
  }
}
