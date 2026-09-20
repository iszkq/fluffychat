// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/adaptive_bottom_sheet.dart';
import 'package:fluffychat/utils/date_time_extension.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class SeenByRow extends StatelessWidget {
  final Event event;
  const SeenByRow({super.key, required this.event});

  Future<void> _showReadReceiptDetails(
    BuildContext context,
    List<Receipt> receipts,
  ) => showAdaptiveBottomSheet(
    context: context,
    builder: (sheetContext) {
      final l10n = L10n.of(sheetContext);
      return Scaffold(
        appBar: AppBar(
          title: Text('${l10n.readBy} (${receipts.length})'),
          leading: CloseButton(
            onPressed: Navigator.of(sheetContext, rootNavigator: false).pop,
          ),
        ),
        body: ListView.separated(
          itemCount: receipts.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final receipt = receipts[index];
            final user = receipt.user;
            return ListTile(
              leading: Avatar(
                mxContent: user.avatarUrl,
                name: user.calcDisplayname(),
                client: event.room.client,
                presenceUserId: user.id,
              ),
              title: Text(user.calcDisplayname()),
              subtitle: Text(user.id),
              trailing: Text(
                receipt.time.localizedDetailedTime(context),
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            );
          },
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    const maxAvatars = 7;
    return StreamBuilder(
      stream: event.room.client.onSync.stream.where(
        (syncUpdate) =>
            syncUpdate.rooms?.join?[event.room.id]?.ephemeral?.any(
              (ephemeral) => ephemeral.type == 'm.receipt',
            ) ??
            false,
      ),
      builder: (context, asyncSnapshot) {
        final seenByReceipts =
            event.receipts
                .where(
                  (receipt) =>
                      receipt.user.id != event.room.client.userID &&
                      receipt.user.id != event.senderId,
                )
                .toList()
              ..sort((a, b) => b.time.compareTo(a.time));
        final seenByUsers = seenByReceipts
            .map((receipt) => receipt.user)
            .toList();
        return Container(
          width: double.infinity,
          alignment: Alignment.center,
          child: AnimatedContainer(
            constraints: const BoxConstraints(
              maxWidth: FluffyThemes.maxTimelineWidth,
            ),
            height: seenByUsers.isEmpty ? 0 : 24,
            duration: seenByUsers.isEmpty
                ? Duration.zero
                : FluffyThemes.animationDuration,
            curve: FluffyThemes.animationCurve,
            alignment: event.senderId == Matrix.of(context).client.userID
                ? Alignment.topRight
                : Alignment.topLeft,
            padding: const EdgeInsets.only(
              bottom: 4,
              top: 1,
              left: 8,
              right: 8,
            ),
            child: Tooltip(
              message: L10n.of(context).readBy,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: seenByReceipts.isEmpty
                    ? null
                    : () => _showReadReceiptDetails(context, seenByReceipts),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Wrap(
                    spacing: 4,
                    children: [
                      ...(seenByUsers.length > maxAvatars
                              ? seenByUsers.sublist(0, maxAvatars)
                              : seenByUsers)
                          .map(
                            (user) => Avatar(
                              mxContent: user.avatarUrl,
                              name: user.calcDisplayname(),
                              size: 16,
                            ),
                          ),
                      if (seenByUsers.length > maxAvatars)
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: Material(
                            color: theme.colorScheme.surface,
                            borderRadius: BorderRadius.circular(32),
                            child: Center(
                              child: Text(
                                '+${seenByUsers.length - maxAvatars}',
                                style: const TextStyle(fontSize: 9),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
