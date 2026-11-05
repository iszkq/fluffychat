// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:matrix/matrix.dart';

/// Records only state transitions and elapsed time, never account credentials.
abstract class SessionDiagnostics {
  static final _lastQr = Expando<DateTime>();

  static void qrStarted(Client client) {
    _lastQr[client] = DateTime.now();
    Logs().i('[Session] QR authorization started on existing device');
  }

  static void attach(Client client) {
    client.onSessionCleared.stream.listen((reason) {
      final qr = _lastQr[client];
      // SDK clear() empties the old log buffer. Emit the reason afterwards so
      // a report collected from the logged-out screen retains the evidence.
      Logs().w(
        '[Session] Local session cleared: ${reason.name}; '
        'seconds since QR: ${qr == null ? 'none' : DateTime.now().difference(qr).inSeconds}',
      );
    });
  }
}
