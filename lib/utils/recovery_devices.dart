// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';

/// Query this account only. The general SDK refresh first enumerates encrypted
/// room members, which must not block recovery of the user's own devices.
/// Keep the SDK's signature, changed-key and seen-device protections. This only
/// discovers devices; no device gains trust until Matrix verification completes.
Future<void> refreshRecoveryDevices(Client client) async {
  final userId = client.userID;
  final deviceId = client.deviceID;
  if (userId == null || deviceId == null) return;
  final response = await client.queryKeys({userId: []}, timeout: 10000);
  bool active() => client.userID == userId && client.deviceID == deviceId;
  if (!active()) return;
  final raw = response.deviceKeys?[userId];
  if (raw == null) throw StateError('Device query returned no account devices');
  final database = client.database;
  final known = client.userDeviceKeys[userId] ?? DeviceKeysList(userId, client);
  final accepted = <String, DeviceKeys>{};
  for (final entry in raw.entries) {
    final old = known.deviceKeys[entry.key];
    final key = DeviceKeys.fromMatrixDeviceKeys(
      entry.value,
      client,
      old?.lastActive,
    );
    final ed = key.ed25519Key;
    final curve = key.curve25519Key;
    if (key.userId != userId ||
        key.deviceId != entry.key ||
        !key.isValid ||
        ed == null ||
        curve == null) {
      continue;
    }
    if (old != null) {
      if (old.ed25519Key == ed && old.curve25519Key == curve) {
        // Retain local block/trust state and current signatures. The normal
        // SDK sync will merge updated signatures through its usual pipeline.
        accepted[entry.key] = old;
      }
      continue;
    }
    final seen = await database.deviceIdSeen(userId, entry.key);
    final seenEd = await database.publicKeySeen(ed);
    final seenCurve = await database.publicKeySeen(curve);
    if ((seen != null && seen != curve + ed) ||
        (seenEd != null && seenEd != entry.key) ||
        (seenCurve != null && seenCurve != entry.key)) {
      continue;
    }
    accepted[entry.key] = key;
  }
  if (!active() || accepted.isEmpty) return;
  await database.transaction(() async {
    for (final entry in accepted.entries) {
      final key = entry.value;
      await database.addSeenDeviceId(
        userId,
        entry.key,
        key.curve25519Key! + key.ed25519Key!,
      );
      await database.addSeenPublicKey(key.ed25519Key!, entry.key);
      await database.addSeenPublicKey(key.curve25519Key!, entry.key);
    }
  });
  if (!active()) return;
  final current = client.userDeviceKeys[userId] ?? known;
  // Preserve entries concurrently refreshed by sync; never replace its identity
  // or cross-signing keys using this discovery-only request.
  for (final entry in accepted.entries) {
    current.deviceKeys.putIfAbsent(entry.key, () => entry.value);
  }
  client.userDeviceKeys[userId] = current;
}
