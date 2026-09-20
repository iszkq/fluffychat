// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:async/async.dart';
import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/services/voice_transcription_service.dart';
import 'package:fluffychat/utils/file_description.dart';
import 'package:fluffychat/utils/localized_exception_extension.dart';
import 'package:fluffychat/utils/url_launcher.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:ogg_caf_converter/ogg_caf_converter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:universal_html/html.dart' as html;

import '../../../utils/matrix_sdk_extensions/event_extension.dart';
import '../../../widgets/fluffy_chat_app.dart';
import '../../../widgets/matrix.dart';

class AudioPlayerWidget extends StatefulWidget {
  final Color color;
  final Color linkColor;
  final double fontSize;
  final Event event;

  static const int wavesCount = 40;

  const AudioPlayerWidget(
    this.event, {
    required this.color,
    required this.linkColor,
    required this.fontSize,
    super.key,
  });

  @override
  AudioPlayerState createState() => AudioPlayerState();
}

enum AudioPlayerStatus { notDownloaded, downloading, downloaded }

class AudioPlayerState extends State<AudioPlayerWidget> {
  static const double buttonSize = 36;

  AudioPlayerStatus status = AudioPlayerStatus.notDownloaded;
  double? _downloadProgress;

  late final MatrixState matrix;
  List<int>? _waveform;
  String? _durationString;
  String? _transcription;
  bool _isTranscribing = false;
  bool _transcriptionExpanded = true;

  @override
  void dispose() {
    super.dispose();
    final audioPlayer = matrix.voiceMessageEventId.value != widget.event.eventId
        ? null
        : matrix.audioPlayer;
    if (audioPlayer != null) {
      if (audioPlayer.playing && !audioPlayer.isAtEndPosition) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          ScaffoldMessenger.of(matrix.context).showMaterialBanner(
            MaterialBanner(
              padding: EdgeInsets.zero,
              leading: StreamBuilder(
                stream: audioPlayer.playerStateStream.asBroadcastStream(),
                builder: (context, _) => IconButton(
                  onPressed: () {
                    if (audioPlayer.isAtEndPosition) {
                      audioPlayer.seek(Duration.zero);
                    } else if (audioPlayer.playing) {
                      audioPlayer.pause();
                    } else {
                      audioPlayer.play();
                    }
                  },
                  icon: audioPlayer.playing && !audioPlayer.isAtEndPosition
                      ? const Icon(Icons.pause_outlined)
                      : const Icon(Icons.play_arrow_outlined),
                ),
              ),
              content: StreamBuilder(
                stream: audioPlayer.positionStream.asBroadcastStream(),
                builder: (context, _) => GestureDetector(
                  onTap: () => FluffyChatApp.router.go(
                    '/rooms/${widget.event.room.id}?event=${widget.event.eventId}',
                  ),
                  child: Text(
                    '🎙️ ${audioPlayer.position.minuteSecondString} / ${audioPlayer.duration?.minuteSecondString} - ${widget.event.senderFromMemoryOrFallback.calcDisplayname()}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              actions: [
                IconButton(
                  onPressed: () {
                    audioPlayer.pause();
                    audioPlayer.dispose();
                    matrix.revokeAudioObjectUrl();
                    matrix.voiceMessageEventId.value = matrix.audioPlayer =
                        null;

                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      ScaffoldMessenger.of(
                        matrix.context,
                      ).clearMaterialBanners();
                    });
                  },
                  icon: const Icon(Icons.close_outlined),
                ),
              ],
            ),
          );
        });
        return;
      }
      audioPlayer.pause();
      audioPlayer.dispose();
      matrix.revokeAudioObjectUrl();
      matrix.voiceMessageEventId.value = matrix.audioPlayer = null;
    }
  }

  Future<void> _onButtonTap() async {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ScaffoldMessenger.of(matrix.context).clearMaterialBanners();
    });
    final currentPlayer =
        matrix.voiceMessageEventId.value != widget.event.eventId
        ? null
        : matrix.audioPlayer;
    if (currentPlayer != null && !currentPlayer.isAtEndPosition) {
      if (currentPlayer.playing) {
        currentPlayer.pause();
      } else {
        currentPlayer.play();
      }
      return;
    }

    matrix.voiceMessageEventId.value = widget.event.eventId;
    matrix.audioPlayer
      ?..stop()
      ..dispose();
    matrix.revokeAudioObjectUrl();
    File? file;
    MatrixFile? matrixFile;

    setState(() => status = AudioPlayerStatus.downloading);
    try {
      final fileSize = widget.event.content
          .tryGetMap<String, Object?>('info')
          ?.tryGet<int>('size');
      matrixFile = await widget.event.downloadAndDecryptAttachment(
        onDownloadProgress: fileSize != null && fileSize > 0
            ? (progress) {
                if (!mounted) return;
                final progressPercentage = progress / fileSize;
                setState(() {
                  _downloadProgress = progressPercentage < 1
                      ? progressPercentage
                      : null;
                });
              }
            : null,
      );

      final attachmentUrl = widget.event.attachmentOrThumbnailMxcUrl();
      final audioFormat = _detectAudioFormat(matrixFile);

      if (!kIsWeb && attachmentUrl != null) {
        final tempDir = await getTemporaryDirectory();
        final fileName = Uri.encodeComponent(attachmentUrl.pathSegments.last);
        file = File('${tempDir.path}/$fileName.${audioFormat.extension}');

        await file.writeAsBytes(matrixFile.bytes);

        if (Platform.isIOS && audioFormat.isOgg) {
          Logs().v('Convert ogg audio file for iOS...');
          final convertedFile = File('${file.path}.caf');
          if (await convertedFile.exists() == false) {
            await OggCafConverter().convertOggToCaf(
              input: file.path,
              output: convertedFile.path,
            );
          }
          file = convertedFile;
        }
      }

      if (!mounted) return;
      setState(() {
        status = AudioPlayerStatus.downloaded;
      });
    } catch (e, s) {
      Logs().v('Could not download audio file', e, s);
      if (!mounted) return;
      setState(() => status = AudioPlayerStatus.notDownloaded);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      return;
    }
    if (!context.mounted) return;
    if (matrix.voiceMessageEventId.value != widget.event.eventId) return;

    final audioPlayer = matrix.audioPlayer = AudioPlayer();

    try {
      if (file != null) {
        // Loading must finish before play() is invoked. Not awaiting this was
        // a race that mainly showed up as silent playback on slower phones.
        await audioPlayer.setFilePath(file.path);
      } else if (kIsWeb) {
        final audioFormat = _detectAudioFormat(matrixFile);
        final blob = html.Blob([matrixFile.bytes], audioFormat.mimeType);
        final objectUrl = html.Url.createObjectUrlFromBlob(blob);
        matrix.audioObjectUrl = objectUrl;
        await audioPlayer.setUrl(objectUrl);
      } else {
        await audioPlayer.setAudioSource(
          AudioSource.uri(
            Uri.dataFromBytes(
              matrixFile.bytes,
              mimeType: _detectAudioFormat(matrixFile).mimeType,
            ),
          ),
        );
      }
      if (!mounted) return;
      await audioPlayer.play();
    } catch (e, s) {
      Logs().w('Unable to play audio message', e, s);
      await audioPlayer.dispose();
      matrix.revokeAudioObjectUrl();
      matrix.voiceMessageEventId.value = matrix.audioPlayer = null;
      if (!mounted) return;
      setState(() => status = AudioPlayerStatus.notDownloaded);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
    }
  }

  ({String extension, String mimeType, bool isOgg}) _detectAudioFormat(
    MatrixFile file,
  ) {
    final bytes = file.bytes;
    final declaredMime = file.mimeType.split(';').first.trim().toLowerCase();
    final fileName = file.name.toLowerCase();

    bool startsWith(List<int> signature, [int offset = 0]) {
      if (bytes.length < signature.length + offset) return false;
      for (var i = 0; i < signature.length; i++) {
        if (bytes[offset + i] != signature[i]) return false;
      }
      return true;
    }

    if (startsWith(const [0x4f, 0x67, 0x67, 0x53])) {
      return (extension: 'ogg', mimeType: 'audio/ogg', isOgg: true);
    }
    if (startsWith(const [0x52, 0x49, 0x46, 0x46]) &&
        startsWith(const [0x57, 0x41, 0x56, 0x45], 8)) {
      return (extension: 'wav', mimeType: 'audio/wav', isOgg: false);
    }
    if (startsWith(const [0x66, 0x4c, 0x61, 0x43])) {
      return (extension: 'flac', mimeType: 'audio/flac', isOgg: false);
    }
    // ADTS AAC also starts with an MPEG-style 0xff sync byte, so it must be
    // detected before the broader MP3 frame check below.
    if (bytes.length >= 2 && bytes[0] == 0xff && (bytes[1] & 0xf6) == 0xf0) {
      return (extension: 'aac', mimeType: 'audio/aac', isOgg: false);
    }
    if (startsWith(const [0x49, 0x44, 0x33]) ||
        (bytes.length >= 2 && bytes[0] == 0xff && (bytes[1] & 0xe0) == 0xe0)) {
      return (extension: 'mp3', mimeType: 'audio/mpeg', isOgg: false);
    }
    if (startsWith(const [0x1a, 0x45, 0xdf, 0xa3])) {
      return (extension: 'webm', mimeType: 'audio/webm', isOgg: false);
    }
    if (startsWith(const [0x23, 0x21, 0x41, 0x4d, 0x52])) {
      return (extension: 'amr', mimeType: 'audio/amr', isOgg: false);
    }
    if (startsWith(const [0x66, 0x74, 0x79, 0x70], 4)) {
      return (extension: 'm4a', mimeType: 'audio/mp4', isOgg: false);
    }

    final isOgg =
        declaredMime.contains('ogg') ||
        fileName.endsWith('.ogg') ||
        fileName.endsWith('.opus');
    if (isOgg) {
      return (extension: 'ogg', mimeType: 'audio/ogg', isOgg: true);
    }

    const mimeFormats = {
      'audio/aac': ('aac', 'audio/aac'),
      'audio/mp4': ('m4a', 'audio/mp4'),
      'audio/mpeg': ('mp3', 'audio/mpeg'),
      'audio/wav': ('wav', 'audio/wav'),
      'audio/x-wav': ('wav', 'audio/wav'),
      'audio/flac': ('flac', 'audio/flac'),
      'audio/webm': ('webm', 'audio/webm'),
      'audio/amr': ('amr', 'audio/amr'),
      'audio/3gpp': ('3gp', 'audio/3gpp'),
    };
    final format = mimeFormats[declaredMime];
    if (format != null) {
      return (extension: format.$1, mimeType: format.$2, isOgg: false);
    }

    final extension = fileName.contains('.')
        ? fileName.split('.').last.replaceAll(RegExp('[^a-z0-9]'), '')
        : 'audio';
    return (
      extension: extension.isEmpty ? 'audio' : extension,
      mimeType: declaredMime.isEmpty
          ? 'application/octet-stream'
          : declaredMime,
      isOgg: false,
    );
  }

  Future<void> _transcribe() async {
    if (_isTranscribing) return;
    setState(() => _isTranscribing = true);
    try {
      final audioFile = await widget.event.downloadAndDecryptAttachment();
      final transcription = await const VoiceTranscriptionService().transcribe(
        audioFile,
      );
      if (!mounted) return;
      setState(() {
        _transcription = transcription;
        _transcriptionExpanded = true;
      });
    } on VoiceTranscriptionNotConfiguredException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).voiceTranscriptionNotConfigured),
        ),
      );
    } catch (e, s) {
      Logs().w('Unable to transcribe voice message', e, s);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).voiceTranscriptionFailed)),
      );
    } finally {
      if (mounted) setState(() => _isTranscribing = false);
    }
  }

  void _onTranscriptionButtonPressed() {
    if (_isTranscribing) return;
    if (_transcription == null) {
      _transcribe();
      return;
    }
    setState(() => _transcriptionExpanded = !_transcriptionExpanded);
  }

  Future<void> _toggleSpeed() async {
    final audioPlayer = matrix.audioPlayer;
    if (audioPlayer == null) return;
    switch (audioPlayer.speed) {
      case 1.0:
        await audioPlayer.setSpeed(1.25);
        break;
      case 1.25:
        await audioPlayer.setSpeed(1.5);
        break;
      case 1.5:
        await audioPlayer.setSpeed(2.0);
        break;
      case 2.0:
        await audioPlayer.setSpeed(0.5);
        break;
      case 0.5:
      default:
        await audioPlayer.setSpeed(1.0);
        break;
    }
    setState(() {});
  }

  List<int>? _getWaveform() {
    final eventWaveForm = widget.event.content
        .tryGetMap<String, Object?>('org.matrix.msc1767.audio')
        ?.tryGetList<int>('waveform');
    if (eventWaveForm == null || eventWaveForm.isEmpty) {
      return null;
    }
    // Newer versions of this MSC define 256 as the maximum instead of 1024.
    // Hard to determine which version we should follow. At the time of writing
    // this, Element X still sends 1024 while Mautrix WhatsApp uses 256.
    // https://github.com/matrix-org/matrix-spec-proposals/blob/travis/msc/audio-waveform/proposals/3246-audio-waveform.md#unstable-prefix
    if (!eventWaveForm.any((value) => value > 256)) {
      _maxWaveForm = 256;
    }

    while (eventWaveForm.length < AudioPlayerWidget.wavesCount) {
      for (var i = 0; i < eventWaveForm.length; i = i + 2) {
        eventWaveForm.insert(i, eventWaveForm[i]);
      }
    }
    var i = 0;
    final step = (eventWaveForm.length / AudioPlayerWidget.wavesCount).round();
    while (eventWaveForm.length > AudioPlayerWidget.wavesCount) {
      eventWaveForm.removeAt(i);
      i = (i + step) % AudioPlayerWidget.wavesCount;
    }
    return eventWaveForm
        .map((i) => i > _maxWaveForm ? _maxWaveForm : i)
        .toList();
  }

  int _maxWaveForm = 1024;

  @override
  void initState() {
    super.initState();
    matrix = Matrix.of(context);
    _waveform = _getWaveform();

    if (matrix.voiceMessageEventId.value == widget.event.eventId &&
        matrix.audioPlayer != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(matrix.context).clearMaterialBanners();
      });
    }

    final durationInt = widget.event.content
        .tryGetMap<String, Object?>('info')
        ?.tryGet<int>('duration');
    if (durationInt != null) {
      final duration = Duration(milliseconds: durationInt);
      _durationString = duration.minuteSecondString;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final waveform = _waveform;

    return ValueListenableBuilder(
      valueListenable: matrix.voiceMessageEventId,
      builder: (context, eventId, _) {
        final audioPlayer = eventId != widget.event.eventId
            ? null
            : matrix.audioPlayer;

        final fileDescription = widget.event.fileDescription;

        return StreamBuilder<Object>(
          stream: audioPlayer == null
              ? null
              : StreamGroup.merge([
                  audioPlayer.positionStream.asBroadcastStream(),
                  audioPlayer.playerStateStream.asBroadcastStream(),
                ]),
          builder: (context, _) {
            final maxPosition =
                audioPlayer?.duration?.inMilliseconds.toDouble() ?? 1.0;
            var currentPosition =
                audioPlayer?.position.inMilliseconds.toDouble() ?? 0.0;
            if (currentPosition > maxPosition) currentPosition = maxPosition;

            final wavePosition =
                (currentPosition / maxPosition) * AudioPlayerWidget.wavesCount;

            final statusText = audioPlayer == null
                ? _durationString ?? '00:00'
                : audioPlayer.position.minuteSecondString;
            return Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                mainAxisSize: .min,
                crossAxisAlignment: .start,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: FluffyThemes.columnWidth,
                    ),
                    child: Row(
                      mainAxisSize: .min,
                      children: <Widget>[
                        SizedBox(
                          width: buttonSize,
                          height: buttonSize,
                          child: status == AudioPlayerStatus.downloading
                              ? CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: widget.color,
                                  value: _downloadProgress,
                                )
                              : InkWell(
                                  borderRadius: BorderRadius.circular(64),
                                  onLongPress: () =>
                                      widget.event.saveFile(context),
                                  onTap: _onButtonTap,
                                  child: Material(
                                    color: widget.color.withAlpha(64),
                                    borderRadius: BorderRadius.circular(64),
                                    child: Icon(
                                      audioPlayer?.playing == true &&
                                              audioPlayer?.isAtEndPosition ==
                                                  false
                                          ? Icons.pause_outlined
                                          : Icons.play_arrow_outlined,
                                      color: widget.color,
                                    ),
                                  ),
                                ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Stack(
                            children: [
                              if (waveform != null)
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16.0,
                                  ),
                                  child: Row(
                                    children: [
                                      for (
                                        var i = 0;
                                        i < AudioPlayerWidget.wavesCount;
                                        i++
                                      )
                                        Expanded(
                                          child: Container(
                                            height: 32,
                                            alignment: Alignment.center,
                                            child: Container(
                                              margin:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 1,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: i < wavePosition
                                                    ? widget.color
                                                    : widget.color.withAlpha(
                                                        128,
                                                      ),
                                                borderRadius:
                                                    BorderRadius.circular(64),
                                              ),
                                              height:
                                                  32 *
                                                  (waveform[i] / _maxWaveForm),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              SizedBox(
                                height: 32,
                                child: Slider(
                                  thumbColor:
                                      widget.event.senderId ==
                                          widget.event.room.client.userID
                                      ? theme.colorScheme.onPrimary
                                      : theme.colorScheme.primary,
                                  activeColor: waveform == null
                                      ? widget.color
                                      : Colors.transparent,
                                  inactiveColor: waveform == null
                                      ? widget.color.withAlpha(128)
                                      : Colors.transparent,
                                  max: maxPosition,
                                  value: currentPosition,
                                  onChanged: (position) => audioPlayer == null
                                      ? _onButtonTap()
                                      : audioPlayer.seek(
                                          Duration(
                                            milliseconds: position.round(),
                                          ),
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 36,
                          child: Text(
                            statusText,
                            style: TextStyle(color: widget.color, fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (audioPlayer != null) ...[
                          Material(
                            color: widget.color.withAlpha(64),
                            borderRadius: BorderRadius.circular(
                              AppConfig.borderRadius,
                            ),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(
                                AppConfig.borderRadius,
                              ),
                              onTap: _toggleSpeed,
                              child: SizedBox(
                                width: 32,
                                height: 20,
                                child: Center(
                                  child: Text(
                                    '${audioPlayer.speed}x',
                                    style: TextStyle(
                                      color: widget.color,
                                      fontSize: 9,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                        ],
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints.tightFor(
                            width: 32,
                            height: 32,
                          ),
                          padding: EdgeInsets.zero,
                          tooltip: _transcription == null
                              ? l10n.voiceToText
                              : _transcriptionExpanded
                              ? l10n.collapse
                              : l10n.expand,
                          onPressed: _isTranscribing
                              ? null
                              : _onTranscriptionButtonPressed,
                          icon: _isTranscribing
                              ? SizedBox.square(
                                  dimension: 15,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: widget.color,
                                  ),
                                )
                              : Icon(
                                  _transcription == null
                                      ? Icons.text_snippet_outlined
                                      : _transcriptionExpanded
                                      ? Icons.text_snippet
                                      : Icons.text_snippet_outlined,
                                  size: 20,
                                ),
                          color: widget.color,
                        ),
                      ],
                    ),
                  ),
                  AnimatedSize(
                    duration: FluffyThemes.animationDuration,
                    curve: FluffyThemes.animationCurve,
                    child: _transcription == null || !_transcriptionExpanded
                        ? const SizedBox.shrink()
                        : ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: FluffyThemes.columnWidth,
                            ),
                            child: Container(
                              margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: widget.color.withAlpha(24),
                                borderRadius: BorderRadius.circular(
                                  AppConfig.borderRadius / 2,
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          l10n.voiceTranscription,
                                          style: TextStyle(
                                            color: widget.color,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        tooltip: l10n.copy,
                                        onPressed: () async {
                                          await Clipboard.setData(
                                            ClipboardData(
                                              text: _transcription!,
                                            ),
                                          );
                                          if (!context.mounted) return;
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                l10n.copiedToClipboard,
                                              ),
                                            ),
                                          );
                                        },
                                        icon: const Icon(Icons.copy_outlined),
                                        color: widget.color,
                                      ),
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        tooltip: l10n.collapse,
                                        onPressed: () => setState(
                                          () => _transcriptionExpanded = false,
                                        ),
                                        icon: const Icon(Icons.expand_less),
                                        color: widget.color,
                                      ),
                                    ],
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: SelectableText(
                                      _transcription!,
                                      style: TextStyle(
                                        color: widget.color,
                                        fontSize: widget.fontSize,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ),
                  if (fileDescription != null) ...[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Linkify(
                        text: fileDescription,
                        textScaleFactor: MediaQuery.textScalerOf(
                          context,
                        ).scale(1),
                        style: TextStyle(
                          color: widget.color,
                          fontSize: widget.fontSize,
                        ),
                        options: const LinkifyOptions(humanize: false),
                        linkStyle: TextStyle(
                          color: widget.linkColor,
                          fontSize: widget.fontSize,
                          decoration: TextDecoration.underline,
                          decorationColor: widget.linkColor,
                        ),
                        onOpen: (url) =>
                            UrlLauncher(context, url.url).launchUrl(),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }
}

extension on AudioPlayer {
  bool get isAtEndPosition {
    final duration = this.duration;
    if (duration == null) return true;
    return position >= duration;
  }
}

extension on Duration {
  String get minuteSecondString =>
      '${inMinutes.toString().padLeft(2, '0')}:${(inSeconds % 60).toString().padLeft(2, '0')}';
}
