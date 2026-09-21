// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/sticker_repository.dart';
import 'package:fluffychat/utils/url_launcher.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class StickerPickerDialog extends StatefulWidget {
  final Room room;
  final ImagePackUsage usage;
  final Future<void> Function(ImagePackImageContent) onSelected;

  const StickerPickerDialog({
    required this.onSelected,
    required this.room,
    this.usage = ImagePackUsage.sticker,
    super.key,
  });

  @override
  StickerPickerDialogState createState() => StickerPickerDialogState();
}

class StickerPickerDialogState extends State<StickerPickerDialog> {
  String? searchFilter;
  String? _selectedPackKey;
  List<CloudStickerPack> _cloudPacks = const [];
  Object? _cloudLoadError;
  bool _cloudPacksLoading = false;
  String? _sendingStickerKey;
  final ScrollController _packScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    if (widget.usage == ImagePackUsage.sticker &&
        CloudStickerRepository.indexUri != null) {
      _cloudPacks = CloudStickerRepository.cachedPacks;
      if (CloudStickerRepository.shouldRefresh) {
        _loadCloudPacks();
      }
    }
  }

  @override
  void dispose() {
    _packScrollController.dispose();
    super.dispose();
  }

  void _scrollPacks(double delta) {
    if (!_packScrollController.hasClients) return;
    final position = _packScrollController.position;
    final target = (_packScrollController.offset + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _packScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _handlePackPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_packScrollController.hasClients) {
      return;
    }
    final delta = event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs()
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    if (delta != 0) _scrollPacks(delta);
  }

  Future<void> _loadCloudPacks() async {
    if (_cloudPacksLoading) return;
    if (CloudStickerRepository.indexUri == null) return;
    setState(() {
      _cloudPacksLoading = true;
      _cloudLoadError = null;
    });
    try {
      final packs = await CloudStickerRepository.load();
      if (!mounted) return;
      setState(() => _cloudPacks = packs);
    } catch (error, stackTrace) {
      Logs().w('Unable to load cloud sticker packs', error, stackTrace);
      if (!mounted) return;
      setState(() => _cloudLoadError = error);
    } finally {
      if (mounted) setState(() => _cloudPacksLoading = false);
    }
  }

  Future<void> _selectSticker(String key, ImagePackImageContent sticker) async {
    if (_sendingStickerKey != null) return;
    setState(() => _sendingStickerKey = key);
    try {
      await widget.onSelected(sticker);
    } finally {
      if (mounted) setState(() => _sendingStickerKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final stickerPacks = widget.room.getImagePacks(widget.usage);
    final packSlugs = stickerPacks.keys.toList();
    final allPackKeys = <String>[
      ...packSlugs.map((slug) => 'matrix:$slug'),
      ..._cloudPacks.map((pack) => 'cloud:${pack.id}'),
    ];
    final selectedPackKey = allPackKeys.contains(_selectedPackKey)
        ? _selectedPackKey
        : allPackKeys.firstOrNull;

    final normalizedSearch = searchFilter?.trim().toLowerCase() ?? '';
    final choices = <StickerCatalogEntry>[];
    if (normalizedSearch.isNotEmpty) {
      choices.addAll(
        searchStickerCatalog(
          buildStickerCatalog(widget.room, _cloudPacks, usage: widget.usage),
          normalizedSearch,
        ),
      );
    } else if (selectedPackKey?.startsWith('matrix:') ?? false) {
      final slug = selectedPackKey!.substring('matrix:'.length);
      final pack = stickerPacks[slug];
      if (pack != null) {
        for (final entry in pack.images.entries) {
          choices.add(
            StickerCatalogEntry(
              key: 'matrix:$slug:${entry.key}',
              name: entry.value.body ?? entry.key,
              packName: pack.pack.displayName ?? slug,
              keywords: [
                entry.key,
                if (entry.value.body != null) entry.value.body!,
              ],
              sticker: entry.value,
            ),
          );
        }
      }
    } else if (selectedPackKey?.startsWith('cloud:') ?? false) {
      final id = selectedPackKey!.substring('cloud:'.length);
      final pack = _cloudPacks.where((pack) => pack.id == id).firstOrNull;
      if (pack != null) {
        for (final image in pack.images) {
          choices.add(
            StickerCatalogEntry(
              key: 'cloud:${image.id}',
              name: image.name,
              packName: pack.name,
              keywords: image.keywords,
              sticker: image.asImagePackContent(),
              networkImage: image.thumbUrl,
            ),
          );
        }
      }
    }
    return Material(
      color: theme.colorScheme.onInverseSurface,
      child: SafeArea(
        top: false,
        child: CustomScrollView(
          slivers: <Widget>[
            SliverAppBar(
              floating: true,
              primary: false,
              toolbarHeight: 72,
              scrolledUnderElevation: 0,
              backgroundColor: Colors.transparent,
              automaticallyImplyLeading: false,
              title: TextField(
                autofocus: false,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: theme.colorScheme.secondaryContainer,
                  border: OutlineInputBorder(
                    borderSide: BorderSide.none,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  contentPadding: EdgeInsets.zero,
                  hintText: L10n.of(context).search,
                  hintStyle: TextStyle(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.normal,
                  ),
                  floatingLabelBehavior: FloatingLabelBehavior.never,
                  prefixIcon: const Icon(Icons.search_outlined),
                ),
                onChanged: (s) => setState(() => searchFilter = s),
              ),
            ),
            if (allPackKeys.isNotEmpty ||
                _cloudPacksLoading ||
                _cloudLoadError != null)
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 58,
                  child: Listener(
                    onPointerSignal: _handlePackPointerSignal,
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
                        controller: _packScrollController,
                        thumbVisibility: true,
                        scrollbarOrientation: ScrollbarOrientation.bottom,
                        child: ListView(
                          controller: _packScrollController,
                          padding: const EdgeInsetsDirectional.only(
                            start: 8,
                            end: 8,
                            bottom: 8,
                          ),
                          scrollDirection: Axis.horizontal,
                          children: [
                                for (final slug in packSlugs)
                                  Padding(
                                    padding: const EdgeInsetsDirectional.only(
                                      end: 8,
                                    ),
                                    child: ChoiceChip(
                                      selected:
                                          selectedPackKey == 'matrix:$slug',
                                      label: Text(
                                        stickerPacks[slug]!.pack.displayName ??
                                            slug,
                                      ),
                                      onSelected: (_) => setState(
                                        () => _selectedPackKey = 'matrix:$slug',
                                      ),
                                    ),
                                  ),
                                for (final pack in _cloudPacks)
                                  Padding(
                                    padding: const EdgeInsetsDirectional.only(
                                      end: 8,
                                    ),
                                    child: ChoiceChip(
                                      avatar: const Icon(
                                        Icons.cloud_outlined,
                                        size: 18,
                                      ),
                                      selected:
                                          selectedPackKey == 'cloud:${pack.id}',
                                      label: Text(pack.name),
                                      onSelected: (_) => setState(
                                        () => _selectedPackKey =
                                            'cloud:${pack.id}',
                                      ),
                                    ),
                                  ),
                                if (_cloudPacksLoading)
                                  const Padding(
                                    padding: EdgeInsets.all(16),
                                    child: SizedBox.square(
                                      dimension: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  ),
                                if (_cloudLoadError != null &&
                                    !_cloudPacksLoading)
                                  TextButton.icon(
                                    onPressed: _loadCloudPacks,
                                    icon: const Icon(Icons.cloud_off_outlined),
                                    label: const Text('重试云端贴纸'),
                                  ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (allPackKeys.isEmpty && !_cloudPacksLoading)
              SliverFillRemaining(
                child: Center(
                  child: Column(
                    mainAxisSize: .min,
                    children: [
                      Text(L10n.of(context).noEmotesFound),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => UrlLauncher(
                          context,
                          AppConfig.howDoIGetStickersTutorial,
                        ).launchUrl(),
                        icon: const Icon(Icons.explore_outlined),
                        label: Text(L10n.of(context).discover),
                      ),
                    ],
                  ),
                ),
              ),
            if (allPackKeys.isNotEmpty && choices.isEmpty)
              SliverFillRemaining(
                child: Center(child: Text(L10n.of(context).noEmotesFound)),
              ),
            if (choices.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                sliver: SliverGrid.builder(
                  itemCount: choices.length,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 84,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemBuilder: (context, index) {
                    final choice = choices[index];
                    final sticker = choice.sticker;
                    final sending = _sendingStickerKey == choice.key;
                    return Tooltip(
                      message: sticker.body ?? choice.name,
                      child: InkWell(
                        radius: AppConfig.borderRadius,
                        key: ValueKey(choice.key),
                        onTap: _sendingStickerKey != null
                            ? null
                            : () async {
                                final copy = ImagePackImageContent.fromJson(
                                  sticker.toJson().copy(),
                                );
                                copy.body ??= choice.name;
                                await _selectSticker(choice.key, copy);
                              },
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            if (choice.networkImage != null)
                              Image.network(
                                choice.networkImage.toString(),
                                fit: BoxFit.contain,
                                width: 128,
                                height: 128,
                                gaplessPlayback: true,
                                errorBuilder: (_, _, _) =>
                                    const Icon(Icons.broken_image_outlined),
                              )
                            else
                              AbsorbPointer(
                                child: MxcImage(
                                  uri: sticker.url,
                                  fit: BoxFit.contain,
                                  width: 128,
                                  height: 128,
                                  animated: true,
                                  isThumbnail: false,
                                ),
                              ),
                            if (sending)
                              const ColoredBox(
                                color: Color(0x66000000),
                                child: Center(
                                  child: CircularProgressIndicator.adaptive(),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
