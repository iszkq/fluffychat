// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/utils/platform_infos.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'matrix.dart';

class NtfyTopicTile extends StatelessWidget {
  const NtfyTopicTile({super.key});

  @override
  Widget build(BuildContext context) {
    if (!PlatformInfos.isIOS) return const SizedBox.shrink();

    final pushService = Matrix.of(context).backgroundPush;
    if (pushService == null) return const SizedBox.shrink();

    final isChinese = Localizations.localeOf(context).languageCode == 'zh';
    final client = Matrix.of(context).client;

    return FutureBuilder<String?>(
      future: pushService.getNtfyTopic(client),
      builder: (context, snapshot) {
        final topic = snapshot.data;
        return ListTile(
          leading: const Icon(Icons.notifications_active_outlined),
          title: Text(
            isChinese ? 'ntfy 通知主题' : 'ntfy notification topic',
          ),
          subtitle: Text(
            snapshot.hasError
                ? (isChinese
                      ? '主题读取失败，请重新打开设置'
                      : 'Unable to load topic. Reopen settings.')
                : topic == null
                ? (isChinese
                      ? '正在生成并保存本设备的专属主题…'
                      : 'Generating and saving this device\'s private topic…')
                : topic,
          ),
          trailing: topic == null
              ? null
              : IconButton(
                  tooltip: isChinese ? '复制主题' : 'Copy topic',
                  icon: const Icon(Icons.copy_outlined),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: topic));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          isChinese
                              ? '主题已复制，可在 ntfy 中订阅'
                              : 'Topic copied. Subscribe to it in ntfy.',
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}
