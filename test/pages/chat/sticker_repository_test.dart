// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/pages/chat/sticker_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

void main() {
  StickerCatalogEntry sticker({
    required String key,
    required String name,
    required String packName,
    List<String> keywords = const [],
  }) => StickerCatalogEntry(
    key: key,
    name: name,
    packName: packName,
    keywords: keywords,
    sticker: ImagePackImageContent(
      url: Uri.parse('mxc://example.org/$key'),
      body: name,
      usage: const [ImagePackUsage.sticker],
    ),
  );

  final catalog = [
    sticker(
      key: 'default-happy',
      name: '开心',
      packName: '默认',
      keywords: const ['开心', '高兴'],
    ),
    sticker(
      key: 'cloud-happy',
      name: '开心猫猫',
      packName: '云端猫猫',
      keywords: const ['开心', '猫'],
    ),
    sticker(
      key: 'cloud-sad',
      name: '难过',
      packName: '云端猫猫',
      keywords: const ['伤心'],
    ),
  ];

  test('searches stickers across default and cloud catalog entries', () {
    final results = searchStickerCatalog(catalog, '开心');

    expect(results.map((entry) => entry.key), ['default-happy', 'cloud-happy']);
  });

  test('matches sticker keywords inside a typed sentence', () {
    final results = searchStickerCatalog(
      catalog,
      '我今天很高兴',
      matchKeywordsInsideSentence: true,
    );

    expect(results.single.key, 'default-happy');
  });

  test('does not match short unrelated keywords inside sentences', () {
    final results = searchStickerCatalog(
      catalog,
      '这是一只小猫咪',
      matchKeywordsInsideSentence: true,
    );

    expect(results, isEmpty);
  });
}
