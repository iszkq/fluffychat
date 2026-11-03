// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

typedef CryptoIdentityStatus = ({
  bool connected,
  bool crossSigningEnabled,
  bool initialized,
  bool keyBackupEnabled,
});

/// Keeps recovery pages in sync even when verification starts on another device
/// or secret sharing completes after the verification dialog has closed.
class CryptoIdentityWatcher {
  final Future<CryptoIdentityStatus> Function() read;
  final void Function(CryptoIdentityStatus) onState;
  final void Function(Object) onError;
  final Duration interval;
  final List<Stream<dynamic>> events;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _timer;
  Future<void>? _reading;
  bool _refreshAgain = false;
  bool _disposed = false;

  CryptoIdentityWatcher({
    required this.read,
    required this.onState,
    required this.onError,
    required this.events,
    this.interval = const Duration(seconds: 2),
  });

  void start() {
    for (final event in events) {
      _subscriptions.add(event.listen((_) => unawaited(refresh())));
    }
    _timer = Timer.periodic(interval, (_) => unawaited(refresh()));
    unawaited(refresh());
  }

  Future<void> refresh() async {
    if (_disposed) return;
    if (_reading != null) {
      _refreshAgain = true;
      return _reading;
    }
    final task = _reading = _refresh();
    try {
      await task;
    } finally {
      _reading = null;
    }
  }

  Future<void> _refresh() async {
    do {
      _refreshAgain = false;
      try {
        final state = await read().timeout(const Duration(seconds: 20));
        if (!_disposed) onState(state);
      } catch (error) {
        if (!_disposed) onError(error);
      }
    } while (_refreshAgain && !_disposed);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }
}
