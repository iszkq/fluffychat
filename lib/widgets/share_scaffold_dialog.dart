// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:cross_file/cross_file.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/trust_user_key_dialog.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';

abstract class ShareItem {}

class TextShareItem extends ShareItem {
  final String value;
  TextShareItem(this.value);
}

class ContentShareItem extends ShareItem {
  final Map<String, Object?> value;
  ContentShareItem(this.value);
}

class FileShareItem extends ShareItem {
  final XFile value;
  FileShareItem(this.value);
}

class ShareScaffoldDialog extends StatefulWidget {
  final List<ShareItem> items;

  const ShareScaffoldDialog({required this.items, super.key});

  @override
  State<ShareScaffoldDialog> createState() => _ShareScaffoldDialogState();
}

class _ShareScaffoldDialogState extends State<ShareScaffoldDialog> {
  final TextEditingController _filterController = TextEditingController();

  final Set<String> selectedRoomIds = {};
  bool _isForwarding = false;

  void _toggleRoom(String roomId) {
    setState(() {
      if (!selectedRoomIds.add(roomId)) {
        selectedRoomIds.remove(roomId);
      }
    });
  }

  Future<void> _forwardAction() async {
    if (selectedRoomIds.isEmpty || _isForwarding) {
      throw Exception(
        'Started forward action before a room was selected. This should never happen.',
      );
    }

    final l10n = L10n.of(context);
    final consent = await showOkCancelAlertDialog(
      context: context,
      title: l10n.forwardMessagesToChats(
        widget.items.length,
        selectedRoomIds.length,
      ),
      okLabel: l10n.forward,
      cancelLabel: l10n.cancel,
    );
    if (consent != OkCancelResult.ok || !mounted) return;

    setState(() => _isForwarding = true);

    // Read shared files once. The same in-memory MatrixFile can then be
    // uploaded independently to every selected room.
    final files = <MatrixFile>[];
    try {
      for (final item in widget.items.whereType<FileShareItem>()) {
        final bytes = await item.value.readAsBytes();
        final mimeType =
            item.value.mimeType ??
            lookupMimeType(item.value.name, headerBytes: bytes);
        files.add(
          MatrixFile(
            bytes: bytes,
            name: item.value.name,
            mimeType: mimeType,
          ).detectFileType,
        );
      }
    } catch (e, s) {
      Logs().w('Unable to prepare shared files for forwarding', e, s);
      if (!mounted) return;
      setState(() => _isForwarding = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.unableToForwardMessages)));
      return;
    }

    if (!mounted) return;
    final client = Matrix.of(context).client;
    final failedRoomIds = <String>{};
    for (final roomId in selectedRoomIds) {
      final room = client.getRoomById(roomId);
      if (room == null) {
        failedRoomIds.add(roomId);
        continue;
      }

      try {
        if (!mounted) return;
        final proceed = await showTrustUserInRoomDialog(context, room);
        if (!mounted) return;
        if (!proceed) {
          failedRoomIds.add(roomId);
          continue;
        }

        for (final item in widget.items) {
          if (item is TextShareItem) {
            await room.sendTextEvent(item.value);
          } else if (item is ContentShareItem) {
            await room.sendEvent(item.value.copy());
          }
        }
        for (final file in files) {
          await room.sendFileEvent(file);
        }
      } catch (e, s) {
        Logs().w('Unable to forward messages to room $roomId', e, s);
        failedRoomIds.add(roomId);
      }
    }

    if (!mounted) return;
    if (failedRoomIds.isNotEmpty) {
      setState(() {
        selectedRoomIds
          ..clear()
          ..addAll(failedRoomIds);
        _isForwarding = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.forwardMessagesFailedForChats(failedRoomIds.length),
          ),
        ),
      );
      return;
    }

    context.pop();
  }

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rooms = Matrix.of(context).client.rooms
        .where(
          (room) =>
              room.canSendDefaultMessages &&
              !room.isSpace &&
              room.membership == Membership.join,
        )
        .toList();
    final filter = _filterController.text.trim().toLowerCase();
    return Scaffold(
      appBar: AppBar(
        leading: Center(child: CloseButton(onPressed: context.pop)),
        title: Text(L10n.of(context).share),
      ),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            floating: true,
            toolbarHeight: 72,
            scrolledUnderElevation: 0,
            backgroundColor: Colors.transparent,
            automaticallyImplyLeading: false,
            title: TextField(
              controller: _filterController,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                filled: true,
                fillColor: theme.colorScheme.secondaryContainer,
                border: OutlineInputBorder(
                  borderSide: BorderSide.none,
                  borderRadius: BorderRadius.circular(99),
                ),
                contentPadding: EdgeInsets.zero,
                hintText: L10n.of(context).search,
                hintStyle: TextStyle(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.normal,
                ),
                floatingLabelBehavior: FloatingLabelBehavior.never,
                prefixIcon: IconButton(
                  onPressed: () {},
                  icon: Icon(
                    Icons.search_outlined,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
          ),
          SliverList.builder(
            itemCount: rooms.length,
            itemBuilder: (context, i) {
              final room = rooms[i];
              final displayname = room.getLocalizedDisplayname(
                MatrixLocals(L10n.of(context)),
              );
              final value = selectedRoomIds.contains(room.id);
              final filterOut = !displayname.toLowerCase().contains(filter);
              if (!value && filterOut) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Opacity(
                  opacity: filterOut ? 0.5 : 1,
                  child: FutureBuilder(
                    future: room.loadHeroUsers(),
                    builder: (context, _) => CheckboxListTile.adaptive(
                      checkboxShape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(90),
                      ),
                      controlAffinity: ListTileControlAffinity.trailing,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(
                          AppConfig.borderRadius,
                        ),
                      ),
                      secondary: Avatar(
                        mxContent: room.avatar,
                        name: displayname,
                        size: Avatar.defaultSize * 0.75,
                      ),
                      title: Text(
                        displayname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        room.directChatMatrixID ??
                            L10n.of(context).countParticipants(
                              (room.summary.mJoinedMemberCount ?? 0) +
                                  (room.summary.mInvitedMemberCount ?? 0),
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      value: selectedRoomIds.contains(room.id),
                      onChanged: _isForwarding
                          ? null
                          : (_) => _toggleRoom(room.id),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      bottomNavigationBar: AnimatedSize(
        duration: FluffyThemes.animationDuration,
        curve: FluffyThemes.animationCurve,
        child: selectedRoomIds.isEmpty
            ? const SizedBox.shrink()
            : Material(
                elevation: 8,
                shadowColor: theme.appBarTheme.shadowColor,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: ElevatedButton(
                      onPressed: _isForwarding ? null : _forwardAction,
                      child: _isForwarding
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              '${L10n.of(context).forward} (${selectedRoomIds.length})',
                            ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
