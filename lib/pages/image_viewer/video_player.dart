// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/localized_exception_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/blur_hash.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../../../utils/error_reporter.dart';
import '../../widgets/mxc_image.dart';

class EventVideoPlayer extends StatefulWidget {
  final Event event;

  const EventVideoPlayer(this.event, {super.key});

  @override
  EventVideoPlayerState createState() => EventVideoPlayerState();
}

class EventVideoPlayerState extends State<EventVideoPlayer> {
  ChewieController? _chewieController;
  VideoPlayerController? _videoPlayerController;

  double? _downloadProgress;

  // The video_player package only doesn't support Windows and Linux.
  final _supportsVideoPlayer =
      !PlatformInfos.isWindows && !PlatformInfos.isLinux;

  Future<void> _downloadAction() async {
    if (!_supportsVideoPlayer) {
      widget.event.saveFile(context);
      return;
    }

    try {
      final fileSize = widget.event.content
          .tryGetMap<String, Object?>('info')
          ?.tryGet<int>('size');
      final videoFile = await widget.event.downloadAndDecryptAttachment(
        onDownloadProgress: fileSize == null
            ? null
            : (progress) {
                final progressPercentage = progress / fileSize;
                setState(() {
                  _downloadProgress = progressPercentage < 1
                      ? progressPercentage
                      : null;
                });
              },
      );

      // Dispose the controllers if we already have them.
      _disposeControllers();
      late VideoPlayerController videoPlayerController;

      // Create the VideoPlayerController from the contents of videoFile.
      if (kIsWeb) {
        videoPlayerController = VideoPlayerController.networkUrl(
          Uri.dataFromBytes(videoFile.bytes, mimeType: videoFile.mimeType),
        );
      } else {
        final tempDir = await getTemporaryDirectory();
        final fileNameStr =
            widget.event.attachmentMxcUrl?.pathSegments.last ??
            widget.event.body;
        final fileName = Uri.encodeComponent(fileNameStr);
        final file = File('${tempDir.path}/${fileName}_${videoFile.name}');
        if (await file.exists() == false) {
          await file.writeAsBytes(videoFile.bytes);
        }
        videoPlayerController = VideoPlayerController.file(file);
      }
      _videoPlayerController = videoPlayerController;

      await videoPlayerController.initialize();

      // Create a ChewieController on top.
      setState(() {
        _chewieController = ChewieController(
          videoPlayerController: videoPlayerController,
          optionsTranslation: OptionsTranslation(
            playbackSpeedButtonText: L10n.of(context).playbackSpeed,
            cancelButtonText: L10n.of(context).cancel,
          ),
          showControlsOnInitialize: true,
          showControls: true,
          showOptions: true,
          draggableProgressBar: true,
          allowPlaybackSpeedChanging: true,
          playbackSpeeds: const [0.5, 0.75, 1, 1.25, 1.5, 2],
          autoPlay: true,
          autoInitialize: true,
          looping: true,
          aspectRatio: _videoPlayerController?.value.aspectRatio,
        );
      });
    } on IOException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
    } catch (e, s) {
      if (!mounted) return;
      ErrorReporter(context, 'Unable to play video').onErrorCallback(e, s);
    }
  }

  void _disposeControllers() {
    _chewieController?.dispose();
    _videoPlayerController?.dispose();
    _chewieController = null;
    _videoPlayerController = null;
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _downloadAction();
    });
  }

  static const String fallbackBlurHash = 'L5H2EC=PM+yV0g-mq.wG9c010J}I';

  @override
  Widget build(BuildContext context) {
    final hasThumbnail = widget.event.hasThumbnail;
    final blurHash =
        (widget.event.infoMap as Map<String, dynamic>).tryGet<String>(
          'xyz.amorgan.blurhash',
        ) ??
        fallbackBlurHash;
    final infoMap = widget.event.content.tryGetMap<String, Object?>('info');
    final videoWidth = infoMap?.tryGet<int>('w') ?? 400;
    final videoHeight = infoMap?.tryGet<int>('h') ?? 300;

    final chewieController = _chewieController;
    return chewieController != null
        ? LayoutBuilder(
            builder: (context, constraints) {
              final maxWidth = constraints.maxWidth;
              final maxHeight = constraints.maxHeight;
              final aspectRatio =
                  _videoPlayerController?.value.aspectRatio ??
                  videoWidth / videoHeight;
              var width = maxWidth;
              var height = width / aspectRatio;
              if (height > maxHeight) {
                height = maxHeight;
                width = height * aspectRatio;
              }
              return Center(
                child: SizedBox(
                  width: width,
                  height: height,
                  child: Chewie(controller: chewieController),
                ),
              );
            },
          )
        : Stack(
            children: [
              Center(
                child: Hero(
                  tag: widget.event.eventId,
                  child: hasThumbnail
                      ? MxcImage(
                          event: widget.event,
                          isThumbnail: true,
                          fit: BoxFit.cover,
                          placeholder: (context) => BlurHash(
                            blurhash: blurHash,
                            width: double.infinity,
                            height: double.infinity,
                            fit: BoxFit.cover,
                          ),
                        )
                      : BlurHash(
                          blurhash: blurHash,
                          width: double.infinity,
                          height: double.infinity,
                        ),
                ),
              ),
              Center(
                child: CircularProgressIndicator.adaptive(
                  value: _downloadProgress,
                ),
              ),
            ],
          );
  }
}
