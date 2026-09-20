// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

class StickerCatalogEntry {
  final String key;
  final String name;
  final String packName;
  final List<String> keywords;
  final ImagePackImageContent sticker;
  final Uri? networkImage;

  const StickerCatalogEntry({
    required this.key,
    required this.name,
    required this.packName,
    required this.keywords,
    required this.sticker,
    this.networkImage,
  });

  Iterable<String> get searchTerms sync* {
    yield name;
    yield packName;
    yield* keywords;
  }
}

class CloudStickerRepository {
  static const cacheDuration = Duration(minutes: 15);

  static List<CloudStickerPack> _cachedPacks = const [];
  static DateTime? _cachedAt;
  static Uri? _cachedIndexUri;
  static Future<List<CloudStickerPack>>? _pendingLoad;

  static List<CloudStickerPack> get cachedPacks => _cachedPacks;

  static Uri? get indexUri {
    final uri = Uri.tryParse(AppSettings.cloudStickerIndexUrl.value.trim());
    if (uri == null) return null;
    if (uri.scheme == 'https') return uri;
    if (kIsWeb && !uri.hasScheme) return Uri.base.resolveUri(uri);
    return null;
  }

  static bool get shouldRefresh {
    final uri = indexUri;
    if (uri == null) return false;
    if (_cachedIndexUri != uri || _cachedAt == null) return true;
    return DateTime.now().difference(_cachedAt!) > cacheDuration;
  }

  static Future<List<CloudStickerPack>> load({bool force = false}) {
    final uri = indexUri;
    if (uri == null) return Future.value(const []);

    if (_cachedIndexUri != uri) {
      _cachedIndexUri = uri;
      _cachedPacks = const [];
      _cachedAt = null;
      _pendingLoad = null;
    }
    if (!force && !shouldRefresh) return Future.value(_cachedPacks);
    if (_pendingLoad != null) return _pendingLoad!;

    final pending = _download(uri);
    _pendingLoad = pending;
    return pending.whenComplete(() => _pendingLoad = null);
  }

  static Future<List<CloudStickerPack>> _download(Uri uri) async {
    final response = await http.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Cloud sticker index returned ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid cloud sticker index');
    }

    final packMetadata = <String, Map<String, dynamic>>{
      for (final value in (decoded['packs'] as List<dynamic>? ?? const []))
        if (value is Map<String, dynamic> && value['id'] is String)
          value['id'] as String: value,
    };
    final imagesByPack = <String, List<CloudSticker>>{};
    for (final value in (decoded['items'] as List<dynamic>? ?? const [])) {
      if (value is! Map<String, dynamic>) continue;
      final sticker = CloudSticker.fromJson(value);
      if (sticker == null) continue;
      (imagesByPack[sticker.packId] ??= []).add(sticker);
    }

    final packs = <CloudStickerPack>[];
    for (final entry in packMetadata.entries) {
      final images = imagesByPack[entry.key] ?? const <CloudSticker>[];
      if (images.isEmpty) continue;
      packs.add(
        CloudStickerPack(
          id: entry.key,
          name: entry.value['name'] as String? ?? entry.key,
          images: images,
        ),
      );
    }
    _cachedPacks = packs;
    _cachedAt = DateTime.now();
    return packs;
  }
}

List<StickerCatalogEntry> buildStickerCatalog(
  Room room,
  List<CloudStickerPack> cloudPacks, {
  ImagePackUsage usage = ImagePackUsage.sticker,
}) {
  final entries = <StickerCatalogEntry>[];
  for (final packEntry in room.getImagePacks(usage).entries) {
    final packName = packEntry.value.pack.displayName ?? packEntry.key;
    for (final imageEntry in packEntry.value.images.entries) {
      final name = imageEntry.value.body ?? imageEntry.key;
      entries.add(
        StickerCatalogEntry(
          key: 'matrix:${packEntry.key}:${imageEntry.key}',
          name: name,
          packName: packName,
          keywords: [
            imageEntry.key,
            if (imageEntry.value.body != null) imageEntry.value.body!,
          ],
          sticker: imageEntry.value,
        ),
      );
    }
  }
  if (usage == ImagePackUsage.sticker) {
    for (final pack in cloudPacks) {
      for (final image in pack.images) {
        entries.add(
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
  return entries;
}

List<StickerCatalogEntry> searchStickerCatalog(
  Iterable<StickerCatalogEntry> catalog,
  String query, {
  int? limit,
  bool matchKeywordsInsideSentence = false,
}) {
  final normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) return const [];

  final matches = <({StickerCatalogEntry entry, int score})>[];
  for (final entry in catalog) {
    var bestScore = 0;
    for (final rawTerm in entry.searchTerms) {
      final term = rawTerm.trim().toLowerCase();
      if (term.isEmpty) continue;
      final score = term == normalizedQuery
          ? 400
          : term.startsWith(normalizedQuery)
          ? 300
          : term.contains(normalizedQuery)
          ? 200
          : matchKeywordsInsideSentence &&
                term.runes.length >= 2 &&
                normalizedQuery.contains(term)
          ? 150 + term.runes.length
          : 0;
      if (score > bestScore) bestScore = score;
    }
    if (bestScore > 0) matches.add((entry: entry, score: bestScore));
  }
  matches.sort((a, b) {
    final score = b.score.compareTo(a.score);
    if (score != 0) return score;
    return a.entry.name.compareTo(b.entry.name);
  });
  final entries = matches.map((match) => match.entry);
  return (limit == null ? entries : entries.take(limit)).toList();
}

class CloudStickerPack {
  final String id;
  final String name;
  final List<CloudSticker> images;

  const CloudStickerPack({
    required this.id,
    required this.name,
    required this.images,
  });
}

class CloudSticker {
  final String id;
  final String packId;
  final String name;
  final String fileName;
  final Uri url;
  final Uri thumbUrl;
  final String mimeType;
  final List<String> keywords;

  const CloudSticker({
    required this.id,
    required this.packId,
    required this.name,
    required this.fileName,
    required this.url,
    required this.thumbUrl,
    required this.mimeType,
    required this.keywords,
  });

  static CloudSticker? fromJson(Map<String, dynamic> json) {
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
    return CloudSticker(
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
