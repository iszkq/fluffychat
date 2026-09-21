// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/events/file_send_status_indicator.dart';
import 'package:fluffychat/pages/office_editor/office_editor.dart';
import 'package:fluffychat/utils/file_description.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/url_launcher.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class MessageDownloadContent extends StatelessWidget {
  static const _cardMaxWidth = 420.0;
  static const _actionSize = 44.0;

  final Event event;
  final Color textColor;
  final Color linkColor;

  const MessageDownloadContent(
    this.event, {
    required this.textColor,
    required this.linkColor,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final filename = event.content.tryGet<String>('filename') ?? event.body;
    final filetype = (filename.contains('.')
        ? filename.split('.').last.toUpperCase()
        : event.content
                  .tryGetMap<String, Object?>('info')
                  ?.tryGet<String>('mimetype')
                  ?.toUpperCase() ??
              'UNKNOWN');
    final sizeString = event.sizeString ?? '?MB';
    final fileDescription = event.fileDescription;
    final fileSendingStatus = event.fileSendingStatus;
    final officeDocument =
        PlatformInfos.supportsEmbeddedOffice && isOfficeDocument(filename);
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = constraints.maxWidth.isFinite
            ? math.min(constraints.maxWidth, _cardMaxWidth)
            : _cardMaxWidth;
        return Column(
          mainAxisSize: .min,
          crossAxisAlignment: .start,
          spacing: 8,
          children: [
            SizedBox(
              width: cardWidth,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(
                    AppConfig.borderRadius / 2,
                  ),
                  onTap: officeDocument && fileSendingStatus == null
                      ? () => openOfficeDocument(context, event)
                      : () => event.saveFile(context),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                    child: Row(
                      mainAxisSize: .max,
                      children: [
                        if (fileSendingStatus != null)
                          FileSendStatusIndicator(
                            fileSendingStatus: fileSendingStatus,
                          )
                        else
                          CircleAvatar(
                            radius: 22,
                            backgroundColor: textColor.withAlpha(32),
                            child: Icon(
                              officeDocument
                                  ? Icons.description_outlined
                                  : Icons.file_download_outlined,
                              color: textColor,
                            ),
                          ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: .start,
                            mainAxisSize: .min,
                            children: [
                              Text(
                                filename,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: textColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '$sizeString  ·  $filetype',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: textColor.withAlpha(190),
                                  fontSize: 11,
                                ),
                              ),
                              if (officeDocument && fileSendingStatus == null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    Localizations.localeOf(context)
                                                .languageCode ==
                                            'zh'
                                        ? '点击卡片在线预览/编辑'
                                        : 'Tap the card to preview/edit online',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: linkColor,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (officeDocument && fileSendingStatus == null) ...[
                          const SizedBox(width: 8),
                          Container(
                            width: 1,
                            height: 32,
                            color: textColor.withAlpha(36),
                          ),
                          const SizedBox(width: 8),
                          _FileActionButton(
                            tooltip: L10n.of(context).saveFile,
                            icon: Icons.download_outlined,
                            color: textColor,
                            onPressed: () => event.saveFile(context),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (fileDescription != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 8.0,
                ),
                child: Linkify(
                  text: fileDescription,
                  textScaleFactor: MediaQuery.textScalerOf(context).scale(1),
                  style: TextStyle(
                    color: textColor,
                    fontSize: AppConfig.messageFontSize,
                  ),
                  options: const LinkifyOptions(humanize: false),
                  linkStyle: TextStyle(
                    color: linkColor,
                    fontSize: AppConfig.messageFontSize,
                    decoration: TextDecoration.underline,
                    decorationColor: linkColor,
                  ),
                  onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _FileActionButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  const _FileActionButton({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: Material(
          color: color.withAlpha(22),
          borderRadius: radius,
          child: InkWell(
            onTap: onPressed,
            borderRadius: radius,
            child: SizedBox(
              width: MessageDownloadContent._actionSize,
              height: MessageDownloadContent._actionSize,
              child: Icon(icon, color: color, size: 22),
            ),
          ),
        ),
      ),
    );
  }
}
