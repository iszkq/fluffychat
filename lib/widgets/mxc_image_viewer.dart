// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/l10n/l10n.dart';
import 'package:material_ui/material_ui.dart';

import 'mxc_image.dart';

class MxcImageViewer extends StatefulWidget {
  final Uri mxContent;

  const MxcImageViewer(this.mxContent, {super.key});

  @override
  State<MxcImageViewer> createState() => _MxcImageViewerState();
}

class _MxcImageViewerState extends State<MxcImageViewer> {
  int _quarterTurns = 0;

  @override
  Widget build(BuildContext context) {
    final iconButtonStyle = IconButton.styleFrom(
      backgroundColor: Colors.black.withAlpha(200),
      foregroundColor: Colors.white,
    );
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Scaffold(
        backgroundColor: Colors.black.withAlpha(128),
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          elevation: 0,
          leading: IconButton(
            style: iconButtonStyle,
            icon: const Icon(Icons.close),
            onPressed: Navigator.of(context).pop,
            color: Colors.white,
            tooltip: L10n.of(context).close,
          ),
          backgroundColor: Colors.transparent,
          actions: [
            IconButton(
              style: iconButtonStyle,
              icon: const Icon(Icons.rotate_left),
              onPressed: () =>
                  setState(() => _quarterTurns = (_quarterTurns - 1) % 4),
              color: Colors.white,
              tooltip: L10n.of(context).rotateLeft,
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: IconButton(
                style: iconButtonStyle,
                icon: const Icon(Icons.rotate_right),
                onPressed: () =>
                    setState(() => _quarterTurns = (_quarterTurns + 1) % 4),
                color: Colors.white,
                tooltip: L10n.of(context).rotateRight,
              ),
            ),
          ],
        ),
        body: InteractiveViewer(
          minScale: 1.0,
          maxScale: 10.0,
          onInteractionEnd: (endDetails) {
            if (endDetails.velocity.pixelsPerSecond.dy >
                MediaQuery.sizeOf(context).height * 1.5) {
              Navigator.of(context, rootNavigator: false).pop();
            }
          },
          child: Center(
            child: GestureDetector(
              // Ignore taps to not go back here:
              onTap: () {},
              child: RotatedBox(
                quarterTurns: _quarterTurns,
                child: MxcImage(
                  key: ValueKey(widget.mxContent.toString()),
                  uri: widget.mxContent,
                  fit: BoxFit.contain,
                  isThumbnail: false,
                  animated: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
