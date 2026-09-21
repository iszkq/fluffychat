// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/pages/chat/sticker_repository.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'chat.dart';

class ChatStickerSuggestions extends StatefulWidget {
  final ChatController controller;

  const ChatStickerSuggestions(this.controller, {super.key});

  @override
  State<ChatStickerSuggestions> createState() => _ChatStickerSuggestionsState();
}

class _ChatStickerSuggestionsState extends State<ChatStickerSuggestions> {
  List<CloudStickerPack> _cloudPacks = CloudStickerRepository.cachedPacks;
  String? _sendingKey;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.sendController.addListener(_handleTextChanged);
    _loadCloudStickers();
  }

  @override
  void didUpdateWidget(covariant ChatStickerSuggestions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.sendController.removeListener(_handleTextChanged);
    widget.controller.sendController.addListener(_handleTextChanged);
    _cloudPacks = CloudStickerRepository.cachedPacks;
    _loadCloudStickers();
  }

  @override
  void dispose() {
    widget.controller.sendController.removeListener(_handleTextChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _handleTextChanged() {
    if (!mounted) return;
    setState(() {});
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  void _scrollBy(double delta) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final target = (_scrollController.offset + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final delta = event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs()
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    if (delta != 0) _scrollBy(delta);
  }

  Future<void> _loadCloudStickers() async {
    if (CloudStickerRepository.indexUri == null) return;
    try {
      final packs = await CloudStickerRepository.load();
      if (mounted) setState(() => _cloudPacks = packs);
    } catch (error, stackTrace) {
      Logs().w(
        'Unable to load cloud stickers for inline suggestions',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _sendSticker(StickerCatalogEntry entry) async {
    if (_sendingKey != null) return;
    setState(() => _sendingKey = entry.key);
    try {
      final sticker = ImagePackImageContent.fromJson(
        entry.sticker.toJson().copy(),
      );
      sticker.body ??= entry.name;
      final sent = await widget.controller.sendSticker(sticker);
      if (sent) {
        widget.controller.sendController.clear();
        widget.controller.onInputBarChanged('');
      }
    } finally {
      if (mounted) setState(() => _sendingKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = widget.controller.sendController.text.trim();
    if (query.isEmpty || widget.controller.selectMode) {
      return const SizedBox.shrink();
    }

    final suggestions = searchStickerCatalog(
      buildStickerCatalog(widget.controller.room, _cloudPacks),
      query,
      matchKeywordsInsideSentence: true,
    );
    if (suggestions.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      height: 88,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Listener(
        onPointerSignal: _handlePointerSignal,
        child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: const {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.stylus,
                  PointerDeviceKind.trackpad,
                },
              ),
              child: Scrollbar(
                controller: _scrollController,
                thumbVisibility: suggestions.length > 1,
                scrollbarOrientation: ScrollbarOrientation.bottom,
                child: ListView.separated(
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsetsDirectional.fromSTEB(8, 6, 8, 8),
                  itemCount: suggestions.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final entry = suggestions[index];
                    final sending = _sendingKey == entry.key;
                    return Tooltip(
                      message: '${entry.name} · ${entry.packName}',
                      child: Material(
                        color: theme.colorScheme.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(
                          AppConfig.borderRadius,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: _sendingKey == null
                              ? () => _sendSticker(entry)
                              : null,
                          child: SizedBox(
                            width: 68,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    6,
                                    4,
                                    6,
                                    18,
                                  ),
                                  child: entry.networkImage == null
                                      ? AbsorbPointer(
                                          child: MxcImage(
                                            uri: entry.sticker.url,
                                            fit: BoxFit.contain,
                                            width: 58,
                                            height: 58,
                                            animated: true,
                                            isThumbnail: false,
                                          ),
                                        )
                                      : Image.network(
                                          entry.networkImage.toString(),
                                          fit: BoxFit.contain,
                                          width: 58,
                                          height: 58,
                                          gaplessPlayback: true,
                                          errorBuilder: (_, _, _) => const Icon(
                                            Icons.broken_image_outlined,
                                          ),
                                        ),
                                ),
                                PositionedDirectional(
                                  start: 4,
                                  end: 4,
                                  bottom: 2,
                                  child: Text(
                                    entry.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.labelSmall,
                                  ),
                                ),
                                if (sending)
                                  const Positioned.fill(
                                    child: ColoredBox(
                                      color: Color(0x66000000),
                                      child: Center(
                                        child: SizedBox.square(
                                          dimension: 24,
                                          child:
                                              CircularProgressIndicator.adaptive(),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
        ),
      ),
    );
  }
}
