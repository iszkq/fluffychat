// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../widgets/matrix.dart';

abstract class FluffyShare {
  static OverlayEntry? _copyFeedbackOverlay;

  static Future<void> share(
    String text,
    BuildContext context, {
    bool copyOnly = false,
  }) async {
    final l10n = L10n.of(context);
    if ((PlatformInfos.isMobile || PlatformInfos.isWeb) && !copyOnly) {
      try {
        final renderObject = context.findRenderObject();
        final sharePositionOrigin = renderObject is RenderBox
            ? renderObject.localToGlobal(Offset.zero) & renderObject.size
            : null;
        await SharePlus.instance.share(
          ShareParams(
            text: text,
            sharePositionOrigin: sharePositionOrigin,
            // Opening an email client is a confusing fallback for a share
            // button. If Web Share is unavailable, copy the link below.
            mailToFallbackEnabled: false,
          ),
        );
        return;
      } catch (_) {
        // Web Share is not available in every desktop browser. Copying keeps
        // the action useful and the overlay below makes the result visible
        // even when this was triggered from inside a modal dialog.
      }
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    _showCopyFeedback(context, l10n.copiedToClipboard);
  }

  static void _showCopyFeedback(BuildContext context, String message) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(showCloseIcon: true, content: Text(message)));
      return;
    }

    _copyFeedbackOverlay?.remove();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (overlayContext) {
        final colors = Theme.of(overlayContext).colorScheme;
        return Positioned(
          left: 24,
          right: 24,
          bottom: 24,
          child: SafeArea(
            child: IgnorePointer(
              child: Center(
                child: Material(
                  elevation: 6,
                  color: colors.inverseSurface,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.check_circle_outline,
                          color: colors.onInverseSurface,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            message,
                            style: TextStyle(color: colors.onInverseSurface),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    _copyFeedbackOverlay = entry;
    overlay.insert(entry);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (entry.mounted) entry.remove();
      if (identical(_copyFeedbackOverlay, entry)) {
        _copyFeedbackOverlay = null;
      }
    });
  }

  static Future<void> shareInviteLink(BuildContext context) async {
    final l10n = L10n.of(context);
    final client = Matrix.of(context).client;
    final ownProfile = await client.fetchOwnProfile();
    if (!context.mounted) return;
    await FluffyShare.share(
      l10n.inviteText(
        ownProfile.displayName ?? client.userID!,
        'https://matrix.to/#/${client.userID}?client=im.fluffychat',
      ),
      context,
    );
  }
}
