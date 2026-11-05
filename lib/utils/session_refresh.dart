// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:matrix/matrix.dart';

/// The SDK clears the session for every MatrixException escaping onSoftLogout.
/// A failed gateway or rate limit must instead leave it available for retry.
class RetryableSessionRefresh implements Exception {
  const RetryableSessionRefresh();

  @override
  String toString() => 'Session refresh temporarily unavailable; retry later';
}

Future<void> refreshSessionSafely(Client client) async {
  try {
    await client.refreshAccessToken();
  } on MatrixException catch (error) {
    // Only explicit credential rejection authorizes the SDK to clear data.
    // Keep timeouts, throttling, unsupported endpoints and server errors as
    // recoverable failures. Do not include response bodies or tokens in logs.
    if ({
      'M_UNKNOWN_TOKEN',
      'M_MISSING_TOKEN',
      'M_FORBIDDEN',
      'M_USER_DEACTIVATED',
    }.contains(error.errcode)) {
      rethrow;
    }
    Logs().w(
      '[Session] Refresh deferred (HTTP ${error.response?.statusCode ?? 'unavailable'}); '
      'keeping local session',
    );
    throw const RetryableSessionRefresh();
  }
}
