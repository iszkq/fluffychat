// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:matrix/matrix.dart';

/// Promote permissions cached by older app versions into the SDK's preload
/// store. Merely adding the event type to importantStateEvents does not move
/// existing entries from the separate non-preloaded store.
Future<void> restoreRoomMentionPowerLevels(Room room) async {
  if (room.getState(EventTypes.RoomPowerLevels) != null) return;
  final client = room.client;
  final oldStates = await client.database.getUnimportantRoomEventStatesForRoom(
    client.importantStateEvents
        .where((type) => type != EventTypes.RoomPowerLevels)
        .toList(),
    room,
  );
  for (final state in oldStates) {
    if (state.type != EventTypes.RoomPowerLevels || state.stateKey != '') {
      continue;
    }
    // Prefer a newer state which may have arrived while reading the cache.
    if (room.getState(EventTypes.RoomPowerLevels) != null) return;
    room.setState(state);
    await client.database.transaction(() async {
      await client.database.storeEventUpdate(
        room.id,
        state,
        EventUpdateType.state,
        client,
      );
    });
    return;
  }
}

Future<void> migrateRoomMentionPowerLevels(Client client) async {
  final rooms = await client.database.getRoomList(client);
  for (final room in rooms) {
    await restoreRoomMentionPowerLevels(room);
  }
}
