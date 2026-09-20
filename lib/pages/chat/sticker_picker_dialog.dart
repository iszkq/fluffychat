// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:fluffychat/config/app_config.dart';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/url_launcher.dart';
import 'package:fluffychat/widgets/mxc_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:http/http.dart' as http;
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
  static List<_CloudStickerPack> _cachedCloudPacks = const [];
  static DateTime? _cloudPacksCachedAt;
  static Uri? _cachedCloudIndexUri;

  String? searchFilter;
  String? _selectedPackKey;
  List<_CloudStickerPack> _cloudPacks = const [];
  Object? _cloudLoadError;
  bool _cloudPacksLoading = false;
  String? _sendingStickerKey;
  final ScrollController _packScrollController = ScrollController();
  bool _canScrollPacksBack = false;
  bool _canScrollPacksForward = false;

  @override
  void initState() {
    super.initState();
    _packScrollController.addListener(_updatePackScrollButtons);
    final cloudIndexUri = _cloudIndexUri;
    if (widget.usage == ImagePackUsage.sticker && cloudIndexUri != null) {
      if (_cachedCloudIndexUri != cloudIndexUri) {
        _cachedCloudPacks = const [];
        _cloudPacksCachedAt = null;
        _cachedCloudIndexUri = cloudIndexUri;
      }
      _cloudPacks = _cachedCloudPacks;
      final cacheAge = _cloudPacksCachedAt == null
          ? null
          : DateTime.now().difference(_cloudPacksCachedAt!);
      if (cacheAge == null || cacheAge > const Duration(minutes: 15)) {
        _loadCloudPacks();
      }
    }
  }

  @override
  void dispose() {
    _packScrollController
      ..removeListener(_updatePackScrollButtons)
      ..dispose();
    super.dispose();
  }

  void _updatePackScrollButtons() {
    if (!_packScrollController.hasClients || !mounted) return;
    final position = _packScrollController.position;
    final canGoBack = position.pixels > position.minScrollExtent + 1;
    final canGoForward = position.pixels < position.maxScrollExtent - 1;
    if (canGoBack == _canScrollPacksBack &&
        canGoForward == _canScrollPacksForward) {
      return;
    }
    setState(() {
      _canScrollPacksBack = canGoBack;
      _canScrollPacksForward = canGoForward;
    });
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

  Uri? get _cloudIndexUri {
    final uri = Uri.tryParse(AppSettings.cloudStickerIndexUrl.value.trim());
    if (uri == null) return null;
    if (uri.scheme == 'https') return uri;
    if (kIsWeb && !uri.hasScheme) return Uri.base.resolveUri(uri);
    return null;
  }

  Future<void> _loadCloudPacks() async {
    if (_cloudPacksLoading) return;
    final cloudIndexUri = _cloudIndexUri;
    if (cloudIndexUri == null) return;
    setState(() {
      _cloudPacksLoading = true;
      _cloudLoadError = null;
    });
    try {
      final response = await http
          .get(cloudIndexUri)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Cloud sticker index returned ${response.statusCode}');
      }
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is! Map<String, dynamic>) {
        throw const FormatException('Invalid cloud sticker index');
      }
      final packMetadata = <String, Map<String, dynamic>>{
        for (final value in (json['packs'] as List<dynamic>? ?? const []))
          if (value is Map<String, dynamic> && value['id'] is String)
            value['id'] as String: value,
      };
      final imagesByPack = <String, List<_CloudSticker>>{};
      for (final value in (json['items'] as List<dynamic>? ?? const [])) {
        if (value is! Map<String, dynamic>) continue;
        final sticker = _CloudSticker.fromJson(value);
        if (sticker == null) continue;
        (imagesByPack[sticker.packId] ??= []).add(sticker);
      }
      final packs = <_CloudStickerPack>[];
      for (final entry in packMetadata.entries) {
        final images = imagesByPack[entry.key] ?? const <_CloudSticker>[];
        if (images.isEmpty) continue;
        packs.add(
          _CloudStickerPack(
            id: entry.key,
            name: entry.value['name'] as String? ?? entry.key,
            images: images,
          ),
        );
      }
      if (!mounted) return;
      _cachedCloudPacks = packs;
      _cloudPacksCachedAt = DateTime.now();
      setState(() => _cloudPacks = packs);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _updatePackScrollButtons(),
      );
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

    final choices = <_StickerChoice>[];
    if (selectedPackKey?.startsWith('matrix:') ?? false) {
      final slug = selectedPackKey!.substring('matrix:'.length);
      final pack = stickerPacks[slug];
      if (pack != null) {
        for (final entry in pack.images.entries) {
          choices.add(
            _StickerChoice(
              key: 'matrix:$slug:${entry.key}',
              name: entry.value.body ?? entry.key,
              searchText: '${entry.key} ${entry.value.body ?? ''}',
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
            _StickerChoice(
              key: 'cloud:${image.id}',
              name: image.name,
              searchText: '${image.name} ${image.keywords.join(' ')}',
              sticker: image.asImagePackContent(),
              networkImage: image.thumbUrl,
            ),
          );
        }
      }
    }
    final normalizedSearch = searchFilter?.trim().toLowerCase() ?? '';
    if (normalizedSearch.isNotEmpty) {
      choices.removeWhere(
        (choice) => !choice.searchText.toLowerCase().contains(normalizedSearch),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _updatePackScrollButtons(),
    );

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
                  child: Stack(
                    children: [
                      Listener(
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
                                start: 52,
                                end: 52,
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
                      PositionedDirectional(
                        start: 4,
                        top: 4,
                        child: _PackScrollButton(
                          icon: Icons.chevron_left,
                          onPressed: _canScrollPacksBack
                              ? () => _scrollPacks(-260)
                              : null,
                        ),
                      ),
                      PositionedDirectional(
                        end: 4,
                        top: 4,
                        child: _PackScrollButton(
                          icon: Icons.chevron_right,
                          onPressed: _canScrollPacksForward
                              ? () => _scrollPacks(260)
                              : null,
                        ),
                      ),
                    ],
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

class _PackScrollButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;

  const _PackScrollButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) => Material(
    elevation: onPressed == null ? 0 : 2,
    color: Theme.of(context).colorScheme.surface.withAlpha(238),
    shape: const CircleBorder(),
    child: IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: icon == Icons.chevron_left
          ? L10n.of(context).previous
          : L10n.of(context).next,
      onPressed: onPressed,
      icon: Icon(icon),
    ),
  );
}

class _StickerChoice {
  final String key;
  final String name;
  final String searchText;
  final ImagePackImageContent sticker;
  final Uri? networkImage;

  const _StickerChoice({
    required this.key,
    required this.name,
    required this.searchText,
    required this.sticker,
    this.networkImage,
  });
}

class _CloudStickerPack {
  final String id;
  final String name;
  final List<_CloudSticker> images;

  const _CloudStickerPack({
    required this.id,
    required this.name,
    required this.images,
  });
}

class _CloudSticker {
  final String id;
  final String packId;
  final String name;
  final String fileName;
  final Uri url;
  final Uri thumbUrl;
  final String mimeType;
  final List<String> keywords;

  const _CloudSticker({
    required this.id,
    required this.packId,
    required this.name,
    required this.fileName,
    required this.url,
    required this.thumbUrl,
    required this.mimeType,
    required this.keywords,
  });

  static _CloudSticker? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final packId = json['packId'];
    final name = json['name'];
    final fileName = json['fileName'];
    final url = Uri.tryParse(json['url'] as String? ?? '');
    final thumbUrl = Uri.tryParse(json['thumbUrl'] as String? ?? '');
    if (id is! String ||
        packId is! String ||
        name is! String ||
        fileName is! String ||
        url == null ||
        thumbUrl == null ||
        url.scheme != 'https' ||
        thumbUrl.scheme != 'https') {
      return null;
    }
    return _CloudSticker(
      id: id,
      packId: packId,
      name: name,
      fileName: fileName,
      url: url,
      thumbUrl: thumbUrl,
      mimeType: json['mimeType'] as String? ?? 'image/gif',
      keywords: (json['keywords'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .toList(),
    );
  }

  ImagePackImageContent asImagePackContent() => ImagePackImageContent(
    url: url,
    body: name,
    info: {
      'mimetype': mimeType,
      'xyz.flchat.cloud_sticker': true,
      'xyz.flchat.file_name': fileName,
    },
    usage: const [ImagePackUsage.sticker],
  );
}
