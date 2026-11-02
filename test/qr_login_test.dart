// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluffychat/utils/qr_login/msc4108_channel.dart';
import 'package:fluffychat/utils/qr_login/qr_login_existing_device.dart';
import 'package:fluffychat/utils/qr_login/qr_login_payload.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

List<int> payloadBytes({
  int mode = 3,
  int version = 2,
  String url = 'https://rendezvous.example/session/test',
}) {
  final uri = utf8.encode(url);
  return [
    ...ascii.encode('MATRIX'),
    version,
    mode,
    ...List.generate(32, (i) => i + 128),
    uri.length >> 8,
    uri.length & 255,
    ...uri,
  ];
}

class FakeAccount extends QrLoginAccount {
  bool hasKeys = true;
  bool exists = false;
  int exports = 0;
  bool supportsGrant = true;
  @override
  String get userId => '@alice:example.org';
  @override
  Future<QrLoginAuthMetadata> authMetadata() async => QrLoginAuthMetadata(
    Uri.parse('https://auth.example/'),
    supportsDeviceGrant: supportsGrant,
  );
  @override
  Future<void> ensureSecretsAvailable() async {
    if (!hasKeys) throw const QrLoginException('keys_locked');
  }

  @override
  Future<bool> deviceExists(String deviceId) async => exists;
  @override
  Future<Map<String, Object?>> exportSecrets() async {
    exports++;
    return {
      'cross_signing': {
        'master_key': 'synthetic-master',
        'self_signing_key': 'synthetic-self',
        'user_signing_key': 'synthetic-user',
      },
      'backup': {'key': 'synthetic-backup', 'backup_version': '1'},
    };
  }
}

Map<String, Object?> protocol({
  String uri = 'https://auth.example/verify?user_code=TEST',
}) => {
  'type': 'm.login.protocol',
  'protocol': 'device_authorization_grant',
  'device_id': 'SYNTHETIC_NEW_DEVICE',
  'device_authorization_grant': {
    'verification_uri': 'https://auth.example/verify',
    'verification_uri_complete': uri,
  },
};

class FakeChannel extends Msc4108Channel {
  final List<Map<String, Object?>> incoming;
  final sent = <Map<String, Object?>>[];
  bool connected = false;
  FakeChannel(this.incoming)
    : super(
        Msc4108Transport(
          Uri.parse('https://rendezvous.example/session/test'),
          httpClient: MockClient((_) async => http.Response('', 500)),
        ),
      );
  @override
  String get checkCode => '42';
  @override
  Future<void> connect(List<int> publicKey) async {
    connected = true;
  }

  @override
  Future<void> send(Map<String, Object?> payload) async {
    transport.checkActive();
    sent.add(payload);
  }

  @override
  Future<Map<String, Object?>> receive() async => incoming.removeAt(0);
}

class HandoffAccount extends FakeAccount {
  @override
  String get deviceId => 'SYNTHETIC_PHONE';
  @override
  bool get supportsVerificationHandoff => true;
}

void main() {
  test(
    'missing master seed hands off to SAS after authentication, without recovery input or key export',
    () async {
      final account = HandoffAccount()..hasKeys = false;
      final channel = FakeChannel([
        {...protocol(), 'org.mxchat.device_verification': 1},
        {'type': 'm.login.success'},
      ]);
      final flow = QrLoginExistingDevice(
        account: account,
        payload: QrLoginPayload.fromBytes(payloadBytes()),
        channel: channel,
      );
      await flow.run(
        unlockSecrets: () async =>
            fail('Recovery must not be required for SAS'),
        confirmCode: (_) async => true,
        authorize: (_, _) async {
          account.exists = true;
          return true;
        },
        onSharingSecrets: () => fail('No secret transfer happened'),
      );
      expect(flow.needsDeviceVerification, isTrue);
      expect(account.exports, 0);
      expect(channel.sent.last['org.mxchat.device_verification'], {
        'user_id': account.userId,
        'device_id': account.deviceId,
      });
      expect(channel.sent.last.containsKey('cross_signing'), isFalse);
    },
  );
  test(
    'clients without handoff capability retain recovery and the full secrets bundle',
    () async {
      final account = HandoffAccount()..hasKeys = false;
      final channel = FakeChannel([
        protocol(),
        {'type': 'm.login.success'},
      ]);
      final flow = QrLoginExistingDevice(
        account: account,
        payload: QrLoginPayload.fromBytes(payloadBytes()),
        channel: channel,
      );
      var unlocks = 0;
      await flow.run(
        unlockSecrets: () async {
          unlocks++;
          account.hasKeys = true;
          return true;
        },
        confirmCode: (_) async => true,
        authorize: (_, _) async {
          account.exists = true;
          return true;
        },
        onSharingSecrets: () {},
      );
      expect(unlocks, 1);
      expect(account.exports, 1);
      expect(flow.needsDeviceVerification, isFalse);
      expect(channel.sent.last.containsKey('cross_signing'), isTrue);
      expect(
        channel.sent.last.containsKey('org.mxchat.device_verification'),
        isFalse,
      );
    },
  );
  test('normal Matrix contact and room scans stay on original route', () {
    for (final link in [
      'https://matrix.to/#/@alice:example.org',
      'https://matrix.to/#/#room:example.org',
      'matrix:u/alice:example.org',
      '@alice:example.org',
    ]) {
      expect(
        QrLoginPayload.fromScan(text: link, rawBytes: utf8.encode(link)),
        isNull,
      );
    }
    expect(QrLoginPayload.fromScan(rawBytes: [255, 254, 1, 2, 3, 4]), isNull);
    expect(QrLoginPayload.fromScan(), isNull);
  });
  test(
    'binary QR payload and lossless Latin-1 fallback preserve public key',
    () {
      final bytes = payloadBytes();
      expect(
        QrLoginPayload.fromScan(rawBytes: bytes)!.publicKey,
        bytes.sublist(8, 40),
      );
      expect(
        QrLoginPayload.fromScan(text: latin1.decode(bytes))!.publicKey,
        bytes.sublist(8, 40),
      );
      expect(QrLoginPayload.fromScan(text: 'MATRIX\uFFFD'), isNull);
    },
  );
  test('verification QR modes are not routed to login', () {
    for (final mode in [0, 1, 2]) {
      expect(
        QrLoginPayload.fromScan(rawBytes: payloadBytes(mode: mode)),
        isNull,
      );
    }
  });
  test('invalid/unsupported login QR and unsafe URLs are rejected', () {
    for (final bytes in [
      payloadBytes(version: 3),
      payloadBytes(mode: 4),
      payloadBytes()..removeLast(),
      payloadBytes(url: 'http://example.org/test'),
      payloadBytes(url: 'https://alice:password@example.org/test'),
      payloadBytes(url: 'https://example.org/test#fragment'),
    ]) {
      expect(
        () => QrLoginPayload.fromScan(rawBytes: bytes),
        throwsFormatException,
      );
    }
  });
  test(
    'locked keys or unsupported server stop before secure handshake',
    () async {
      for (final reason in ['keys_locked', 'unsupported_protocol']) {
        final account = FakeAccount()
          ..hasKeys = reason != 'keys_locked'
          ..supportsGrant = reason != 'unsupported_protocol';
        final channel = FakeChannel([]);
        final flow = QrLoginExistingDevice(
          account: account,
          payload: QrLoginPayload.fromBytes(payloadBytes()),
          channel: channel,
        );
        await expectLater(
          flow.run(
            confirmCode: (_) async => true,
            authorize: (_, _) async => true,
            onSharingSecrets: () {},
          ),
          throwsA(
            isA<QrLoginException>().having((e) => e.reason, 'reason', reason),
          ),
        );
        expect(channel.connected, isFalse);
        expect(account.exports, 0);
      }
    },
  );
  test('code rejection never opens authorization or exports keys', () async {
    final account = FakeAccount();
    final channel = FakeChannel([]);
    final flow = QrLoginExistingDevice(
      account: account,
      payload: QrLoginPayload.fromBytes(payloadBytes()),
      channel: channel,
    );
    var opened = false;
    await expectLater(
      flow.run(
        confirmCode: (_) async => false,
        authorize: (_, _) async {
          opened = true;
          return true;
        },
        onSharingSecrets: () {},
      ),
      throwsA(isA<QrLoginException>()),
    );
    expect(opened, isFalse);
    expect(account.exports, 0);
    expect(channel.sent.any((m) => m['type'] == 'm.login.secrets'), isFalse);
  });
  test(
    'local unlock resumes preflight and shares only after new device exists',
    () async {
      final account = FakeAccount()..hasKeys = false;
      final channel = FakeChannel([
        protocol(),
        {'type': 'm.login.success'},
      ]);
      final flow = QrLoginExistingDevice(
        account: account,
        payload: QrLoginPayload.fromBytes(payloadBytes()),
        channel: channel,
      );
      await flow.run(
        unlockSecrets: () async {
          expect(channel.connected, isFalse);
          account.hasKeys = true;
          return true;
        },
        confirmCode: (_) async => true,
        authorize: (_, _) async {
          account.exists = true;
          return true;
        },
        onSharingSecrets: () {},
      );
      expect(account.exports, 1);
      expect(channel.sent.last['type'], 'm.login.secrets');
    },
  );
  test('untrusted authorization origin and path are rejected', () async {
    for (final uri in [
      'https://phishing.example/verify',
      'http://auth.example/verify',
      'https://auth.example@evil.example/verify',
      'https://auth.example/wrong-path',
    ]) {
      final account = FakeAccount();
      final channel = FakeChannel([protocol(uri: uri)]);
      final flow = QrLoginExistingDevice(
        account: account,
        payload: QrLoginPayload.fromBytes(payloadBytes()),
        channel: channel,
      );
      await expectLater(
        flow.run(
          confirmCode: (_) async => true,
          authorize: (_, _) async => fail('Must not open untrusted URI'),
          onSharingSecrets: () {},
        ),
        throwsA(
          isA<QrLoginException>().having(
            (e) => e.reason,
            'reason',
            'authorization_uri_mismatch',
          ),
        ),
      );
      expect(account.exports, 0);
    }
  });
  test(
    'success message alone cannot release keys to a different account',
    () async {
      final account = FakeAccount();
      final channel = FakeChannel([
        protocol(),
        {'type': 'm.login.success'},
      ]);
      final flow = QrLoginExistingDevice(
        account: account,
        payload: QrLoginPayload.fromBytes(payloadBytes()),
        channel: channel,
        deviceWait: Duration.zero,
        devicePollInterval: Duration.zero,
      );
      await expectLater(
        flow.run(
          confirmCode: (_) async => true,
          authorize: (_, _) async => true,
          onSharingSecrets: () {},
        ),
        throwsA(
          isA<QrLoginException>().having(
            (e) => e.reason,
            'reason',
            'device_not_found',
          ),
        ),
      );
      expect(account.exports, 0);
    },
  );
  test('existing device ID is rejected before browser authorization', () async {
    final account = FakeAccount()..exists = true;
    final channel = FakeChannel([protocol()]);
    final flow = QrLoginExistingDevice(
      account: account,
      payload: QrLoginPayload.fromBytes(payloadBytes()),
      channel: channel,
    );
    await expectLater(
      flow.run(
        confirmCode: (_) async => true,
        authorize: (_, _) async => fail('Device already exists'),
        onSharingSecrets: () {},
      ),
      throwsA(
        isA<QrLoginException>().having(
          (e) => e.reason,
          'reason',
          'device_already_exists',
        ),
      ),
    );
    expect(account.exports, 0);
  });
  test(
    'cancel while waiting for code prevents subsequent authorization',
    () async {
      final account = FakeAccount();
      final channel = FakeChannel([]);
      final flow = QrLoginExistingDevice(
        account: account,
        payload: QrLoginPayload.fromBytes(payloadBytes()),
        channel: channel,
      );
      await expectLater(
        flow.run(
          confirmCode: (_) async {
            flow.cancel();
            return true;
          },
          authorize: (_, _) async => fail('Cancelled'),
          onSharingSecrets: () {},
        ),
        throwsA(isA<QrLoginException>()),
      );
      expect(account.exports, 0);
    },
  );
  test('rendezvous never follows redirects or sends a bearer token', () async {
    final transport = Msc4108Transport(
      Uri.parse('https://rendezvous.example/session/test'),
      httpClient: MockClient((request) async {
        expect(request.followRedirects, isFalse);
        expect(request.headers.containsKey('authorization'), isFalse);
        return http.Response(
          '',
          302,
          headers: {'location': 'https://evil.example/'},
        );
      }),
    );
    await expectLater(transport.send('test'), throwsA(isA<QrLoginException>()));
    transport.close();
  });
  test('rendezvous fails on missing ETag, stale writes and expiry', () async {
    for (final status in [200, 404, 410, 412]) {
      final transport = Msc4108Transport(
        Uri.parse('https://rendezvous.example/session/test'),
        httpClient: MockClient((_) async => http.Response('', status)),
      );
      await expectLater(
        transport.send('test'),
        throwsA(isA<QrLoginException>()),
      );
      transport.close();
    }
  });

  final sdkProject = Platform.environment['QR_LOGIN_JS_PROJECT'];
  for (final handoff in [false, true]) {
    test(
      'interoperates with real matrix-js-sdk / Rust ECIES, DAG and ${handoff ? "SAS handoff" : "secrets"} flow',
      () async {
        final peer = await Process.start('node', [
          'scripts/qr_login_test_peer.mjs',
          sdkProject!,
          if (handoff) '--handoff',
        ]);
        final lines = StreamIterator(
          peer.stdout.transform(utf8.decoder).transform(const LineSplitter()),
        );
        final stderr = StringBuffer();
        final stderrSub = peer.stderr
            .transform(utf8.decoder)
            .listen(stderr.write);
        Future<Map<String, Object?>> next() async {
          if (!await lines.moveNext().timeout(const Duration(seconds: 20))) {
            fail('Peer ended: $stderr');
          }
          return jsonDecode(lines.current) as Map<String, Object?>;
        }

        Future<Map<String, Object?>> rpc(Map<String, Object?> command) async {
          peer.stdin.writeln(jsonEncode(command));
          return next();
        }

        try {
          final init = await next();
          final bytes = base64Decode(init['qr'] as String);
          final payload = QrLoginPayload.fromScan(
            rawBytes: List<int>.from(init['raw8'] as List),
          )!;
          expect(payload.publicKey, bytes.sublist(8, 40));
          expect(
            QrLoginPayload.fromScan(
              rawBytes: List<int>.from(init['raw16'] as List),
            )!.publicKey,
            payload.publicKey,
          );
          var pending = Future<void>.value();
          // Serialize test RPCs; production transport is sequential too.
          Future<Map<String, Object?>> serial(Map<String, Object?> request) {
            final result = pending.then((_) => rpc(request));
            pending = result.then((_) {});
            return result;
          }

          final client = MockClient((request) async {
            expect(request.headers.containsKey('authorization'), isFalse);
            if (request.method == 'GET') {
              final data = await serial({'command': 'get'});
              if (request.headers['if-none-match'] == data['etag']) {
                return http.Response('', 304);
              }
              return http.Response(
                data['body'] as String,
                200,
                headers: {
                  'etag': data['etag'] as String,
                  'content-type': 'text/plain',
                },
              );
            }
            final data = await serial({
              'command': 'put',
              'body': request.body,
              'etag': request.headers['if-match'],
            });
            return http.Response(
              '',
              data['status'] as int,
              headers: {
                if (data['etag'] != null) 'etag': data['etag'] as String,
              },
            );
          });
          final account = _PeerAccount(
            () => serial({'command': 'status'}),
            handoff: handoff,
          )..hasKeys = !handoff;
          final flow = QrLoginExistingDevice(
            account: account,
            payload: payload,
            channel: Msc4108Channel(
              Msc4108Transport(
                payload.rendezvous,
                httpClient: client,
                pollInterval: const Duration(milliseconds: 10),
              ),
            ),
          );
          await flow.run(
            confirmCode: (code) async {
              final status = await serial({'command': 'status'});
              expect(code, status['checkCode']);
              return true;
            },
            authorize: (uri, deviceId) async {
              expect(
                uri.toString(),
                'https://auth.example/verify?user_code=TEST',
              );
              expect(deviceId, 'SYNTHETIC_NEW_DEVICE');
              await serial({'command': 'approve'});
              return true;
            },
            onSharingSecrets: () {},
          );
          Map<String, Object?> status;
          do {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            status = await serial({'command': 'status'});
            expect(status['failure'], isNull);
          } while (status['finished'] == null);
          final finished = status['finished'] as Map;
          expect(finished['serverName'], 'example.org');
          expect(finished['tokenReceived'], isTrue);
          final secrets = finished['secrets'] as Map;
          if (handoff) {
            expect(secrets['org.mxchat.device_verification'], {
              'user_id': account.userId,
              'device_id': account.deviceId,
            });
            expect(secrets.containsKey('cross_signing'), isFalse);
            expect(account.exports, 0);
          } else {
            expect(
              (secrets['cross_signing'] as Map)['master_key'],
              'synthetic-master',
            );
            expect((secrets['backup'] as Map)['backup_version'], '1');
            expect(account.exports, 1);
          }
        } finally {
          peer.kill();
          await lines.cancel();
          await stderrSub.cancel();
        }
      },
      skip: sdkProject == null
          ? 'Set QR_LOGIN_JS_PROJECT to a project with matrix-js-sdk and qrcode installed'
          : false,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}

class _PeerAccount extends FakeAccount {
  final Future<Map<String, Object?>> Function() status;
  final bool handoff;
  _PeerAccount(this.status, {this.handoff = false});
  @override
  String get deviceId => 'SYNTHETIC_PHONE';
  @override
  bool get supportsVerificationHandoff => handoff;
  @override
  Future<bool> deviceExists(String deviceId) async =>
      (await status())['newDeviceLoggedIn'] == true;
}
