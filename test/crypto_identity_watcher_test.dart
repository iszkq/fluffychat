// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/utils/crypto_identity_watcher.dart';
import 'package:test/test.dart';

CryptoIdentityStatus status(bool connected) => (
  connected: connected,
  initialized: true,
  keyBackupEnabled: true,
  crossSigningEnabled: true,
);

void main() {
  test(
    'verification initiated elsewhere updates recovery on secret events',
    () async {
      final events = StreamController<void>.broadcast(sync: true);
      var connected = false;
      final observed = <bool>[];
      final watcher = CryptoIdentityWatcher(
        read: () async => status(connected),
        onState: (s) => observed.add(s.connected),
        onError: (e) => fail('$e'),
        events: [events.stream],
      );
      addTearDown(watcher.dispose);
      addTearDown(events.close);
      watcher.start();
      await watcher.refresh();
      connected = true;
      events.add(null);
      await watcher.refresh();
      expect(observed.first, isFalse);
      expect(observed.last, isTrue);
    },
  );

  test(
    'periodic refresh detects late secrets without restarting the app',
    () async {
      final done = Completer<void>();
      var connected = false;
      final watcher = CryptoIdentityWatcher(
        read: () async => status(connected),
        onState: (s) {
          if (s.connected && !done.isCompleted) done.complete();
        },
        onError: (e) => fail('$e'),
        events: [],
        interval: const Duration(milliseconds: 5),
      );
      addTearDown(watcher.dispose);
      watcher.start();
      await watcher.refresh();
      connected = true;
      await done.future.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'events arriving during a read are drained without parallel reads',
    () async {
      final first = Completer<CryptoIdentityStatus>();
      var reads = 0;
      final observed = <bool>[];
      final watcher = CryptoIdentityWatcher(
        read: () {
          reads++;
          return reads == 1 ? first.future : Future.value(status(true));
        },
        onState: (s) => observed.add(s.connected),
        onError: (e) => fail('$e'),
        events: [],
      );
      addTearDown(watcher.dispose);
      final initial = watcher.refresh();
      final queued = watcher.refresh();
      expect(reads, 1);
      first.complete(status(false));
      await Future.wait([initial, queued]);
      expect(reads, 2);
      expect(observed, [false, true]);
    },
  );

  test('temporary read failure remains retryable', () async {
    var failRead = true;
    final errors = <Object>[];
    final observed = <bool>[];
    final watcher = CryptoIdentityWatcher(
      read: () async {
        if (failRead) throw StateError('offline');
        return status(true);
      },
      onState: (s) => observed.add(s.connected),
      onError: errors.add,
      events: [],
    );
    addTearDown(watcher.dispose);
    await watcher.refresh();
    failRead = false;
    await watcher.refresh();
    expect(errors, hasLength(1));
    expect(observed, [true]);
  });

  test('disposed recovery page receives no late async updates', () async {
    final reading = Completer<CryptoIdentityStatus>();
    final observed = <bool>[];
    final watcher = CryptoIdentityWatcher(
      read: () => reading.future,
      onState: (s) => observed.add(s.connected),
      onError: (e) => fail('$e'),
      events: [],
    );
    final task = watcher.refresh();
    watcher.dispose();
    reading.complete(status(true));
    await task;
    expect(observed, isEmpty);
  });
}
