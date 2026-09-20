// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/sticker_picker_dialog.dart';
import 'package:fluffychat/pages/chat/trust_user_key_dialog.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'chat.dart';

class ChatEmojiPicker extends StatelessWidget {
  static const int _maxCloudStickerBytes = 15 * 1024 * 1024;

  final ChatController controller;
  const ChatEmojiPicker(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: FluffyThemes.animationDuration,
      curve: FluffyThemes.animationCurve,
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(),
      height: controller.showEmojiPicker
          ? MediaQuery.sizeOf(context).height / 2
          : 0,
      child: controller.showEmojiPicker
          ? DefaultTabController(
              length: 2,
              child: Column(
                children: [
                  TabBar(
                    tabs: [
                      Tab(text: L10n.of(context).emojis),
                      Tab(text: L10n.of(context).stickers),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        EmojiPicker(
                          onEmojiSelected: controller.onEmojiSelected,
                          onBackspacePressed: controller.emojiPickerBackspace,
                          config: Config(
                            locale: Localizations.localeOf(context),
                            emojiViewConfig: EmojiViewConfig(
                              noRecents: const NoRecent(),
                              backgroundColor:
                                  theme.colorScheme.onInverseSurface,
                            ),
                            bottomActionBarConfig: const BottomActionBarConfig(
                              enabled: false,
                            ),
                            categoryViewConfig: CategoryViewConfig(
                              backspaceColor: theme.colorScheme.primary,
                              iconColor: theme.colorScheme.primary.withAlpha(
                                128,
                              ),
                              iconColorSelected: theme.colorScheme.primary,
                              indicatorColor: theme.colorScheme.primary,
                              backgroundColor: theme.colorScheme.surface,
                            ),
                            skinToneConfig: SkinToneConfig(
                              dialogBackgroundColor: Color.lerp(
                                theme.colorScheme.surface,
                                theme.colorScheme.primaryContainer,
                                0.75,
                              )!,
                              indicatorColor: theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                        StickerPickerDialog(
                          room: controller.room,
                          onSelected: (sticker) async {
                            final proceed = await showTrustUserInRoomDialog(
                              context,
                              controller.room,
                            );
                            if (!proceed) return;
                            try {
                              if (sticker.url.scheme == 'http' ||
                                  sticker.url.scheme == 'https') {
                                final response = await http
                                    .get(sticker.url)
                                    .timeout(const Duration(seconds: 30));
                                if (response.statusCode < 200 ||
                                    response.statusCode >= 300) {
                                  throw Exception(
                                    'Sticker download returned ${response.statusCode}',
                                  );
                                }
                                if (response.bodyBytes.isEmpty ||
                                    response.bodyBytes.length >
                                        _maxCloudStickerBytes) {
                                  throw Exception(
                                    'Cloud sticker has an invalid file size',
                                  );
                                }
                                final originalInfo = sticker.info ?? const {};
                                final mimeType =
                                    originalInfo['mimetype'] as String? ??
                                    response.headers['content-type']
                                        ?.split(';')
                                        .first ??
                                    'image/gif';
                                final fileName =
                                    originalInfo['xyz.flchat.file_name']
                                        as String? ??
                                    'sticker.gif';
                                sticker.url = await controller.room.client
                                    .uploadContent(
                                      response.bodyBytes,
                                      filename: fileName,
                                      contentType: mimeType,
                                    );
                                sticker.info = {
                                  'mimetype': mimeType,
                                  'size': response.bodyBytes.length,
                                };
                              }
                              await controller.room.sendEvent(
                                {
                                  'body': sticker.body,
                                  'info': sticker.info ?? {},
                                  'url': sticker.url.toString(),
                                },
                                type: EventTypes.Sticker,
                                threadRootEventId: controller.activeThreadId,
                                threadLastEventId: controller.threadLastEventId,
                              );
                              controller.hideEmojiPicker();
                            } catch (error, stackTrace) {
                              Logs().w(
                                'Unable to send cloud sticker',
                                error,
                                stackTrace,
                              );
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    L10n.of(context).couldNotBeSent,
                                  ),
                                ),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            )
          : null,
    );
  }
}

class NoRecent extends StatelessWidget {
  const NoRecent({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Text(
          L10n.of(context).emoteKeyboardNoRecents,
          style: Theme.of(context).textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
