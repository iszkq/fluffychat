// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:cross_file/cross_file.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/send_file_dialog.dart';
import 'package:fluffychat/utils/localized_exception_extension.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// The chat page can be disposed when rotating across the split-view breakpoint
/// while the native camera is open. Keep the result attached to the root
/// navigator rather than the chat page's short-lived context.
Future<void> showCameraPhotoDialog({
  required BuildContext context,
  required Room room,
  required Future<XFile?> Function() capturePhoto,
  Future<XFile> Function(XFile)? preparePhoto,
  String? threadRootEventId,
  String? threadLastEventId,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.of(context);
  final l10n = L10n.of(context);

  try {
    var photo = await capturePhoto();
    if (photo == null || !navigator.mounted) return;

    if (preparePhoto != null) {
      try {
        photo = await preparePhoto(photo);
      } catch (error, stackTrace) {
        // Normalization is optional. Never drop a captured photo just because
        // its format cannot be handled by the Dart image decoder.
        Logs().w(
          'Unable to normalize camera photo, using original',
          error,
          stackTrace,
        );
      }
    }
    if (!navigator.mounted) return;

    final file = photo;
    await showAdaptiveDialog<void>(
      context: navigator.context,
      useRootNavigator: true,
      // Do not let the native camera's final Use Photo tap dismiss the preview
      // while its dismissal animation is still returning control to Flutter.
      barrierDismissible: false,
      builder: (_) => SendFileDialog(
        files: [file],
        room: room,
        outerContext: navigator.context,
        threadRootEventId: threadRootEventId,
        threadLastEventId: threadLastEventId,
      ),
    );
  } catch (error, stackTrace) {
    Logs().w('Unable to open camera photo', error, stackTrace);
    if (navigator.mounted && messenger.mounted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${l10n.couldNotBeSent}\n${error.toLocalizedString(navigator.context)}',
          ),
        ),
      );
    }
  }
}
