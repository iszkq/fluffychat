// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat/send_file_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

final _imageBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC',
);

XFile _photo(String name) =>
    XFile.fromData(_imageBytes, name: name, mimeType: 'image/png');

class _DelayedConfigClient implements Client {
  final config = Completer<MediaConfig>();
  Uint8List? compressedBytes;
  final resizeRequests = <MatrixImageFileResizeArguments>[];

  @override
  NativeImplementations get nativeImplementations =>
      NativeImplementations.dummy;

  @override
  Future<MatrixImageFileResizedResponse?> Function(
    MatrixImageFileResizeArguments,
  )
  get customImageResizer => (arguments) async {
    resizeRequests.add(arguments);
    return MatrixImageFileResizedResponse(
      bytes: compressedBytes ?? arguments.bytes,
      width: 1,
      height: 1,
      originalWidth: 1,
      originalHeight: 1,
      mimeType: 'image/png',
    );
  };

  @override
  Future<MediaConfig> getConfig({
    Duration cacheLifetime = const Duration(days: 3),
    bool throwOnUpdateFailure = false,
  }) => config.future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SentFile {
  final MatrixFile file;
  final int? maxDimension;
  final Map<String, dynamic>? extraContent;
  final String? threadRootEventId;
  final String? threadLastEventId;

  _SentFile(
    this.file,
    this.maxDimension,
    this.extraContent,
    this.threadRootEventId,
    this.threadLastEventId,
  );
}

class _TestRoom implements Room {
  @override
  final _DelayedConfigClient client = _DelayedConfigClient();

  @override
  bool get encrypted => false;

  final sentFiles = <_SentFile>[];
  Object? sendError;

  @override
  Future<String?> sendFileEvent(
    MatrixFile file, {
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    int? shrinkImageMaxDimension,
    MatrixImageFile? thumbnail,
    Map<String, dynamic>? extraContent,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
  }) async {
    sentFiles.add(
      _SentFile(
        file,
        shrinkImageMaxDimension,
        extraContent,
        threadRootEventId,
        threadLastEventId,
      ),
    );
    final error = sendError;
    if (error != null) throw error;
    return '\$sent${sentFiles.length}';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<SendFileDialogState> _openDialog(
  WidgetTester tester,
  _TestRoom room,
  List<XFile> files,
) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: [
        ...L10n.localizationsDelegates,
        ...GlobalMaterialLocalizations.delegates,
      ],
      supportedLocales: L10n.supportedLocales,
      theme: ThemeData(platform: TargetPlatform.android),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => SendFileDialog(
                room: room,
                files: files,
                outerContext: context,
                threadRootEventId: '\$thread-root',
                threadLastEventId: '\$thread-last',
              ),
            ),
            child: const Text('Open files'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Open files'));
  await tester.pumpAndSettle();
  return tester.state<SendFileDialogState>(find.byType(SendFileDialog));
}

Future<void> _dismissWhileConfigIsPending(WidgetTester tester) async {
  await tester.pump();
  // The send progress indicator is still running, so do not pumpAndSettle.
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('sends a photo and caption after the dialog has been disposed', (
    tester,
  ) async {
    final room = _TestRoom();
    final state = await _openDialog(tester, room, [_photo('camera.png')]);
    await tester.enterText(find.byType(TextField), '  Camera caption  ');
    await tester.tap(find.byType(Switch));
    await tester.tap(find.text('Send'));
    await _dismissWhileConfigIsPending(tester);

    expect(state.mounted, isFalse);
    expect(room.sentFiles, isEmpty);

    room.client.config.complete(MediaConfig(mUploadSize: 1000000));
    await tester.pumpAndSettle();

    final sent = room.sentFiles.single;
    expect(sent.file.name, 'camera.png');
    expect(sent.file.bytes, _imageBytes);
    expect(sent.maxDimension, isNull);
    expect(sent.extraContent, {'body': 'Camera caption'});
    expect(sent.threadRootEventId, '\$thread-root');
    expect(sent.threadLastEventId, '\$thread-last');
    expect(tester.takeException(), isNull);
  });

  testWidgets('sends every gallery photo once despite repeated send taps', (
    tester,
  ) async {
    final room = _TestRoom();
    final state = await _openDialog(tester, room, [
      _photo('gallery-1.png'),
      _photo('gallery-2.png'),
    ]);
    await tester.tap(find.text('Send'));
    await tester.tap(find.text('Send'));
    await _dismissWhileConfigIsPending(tester);
    expect(state.mounted, isFalse);

    room.client.config.complete(MediaConfig(mUploadSize: 1000000));
    await tester.pumpAndSettle();

    expect(room.sentFiles.map((sent) => sent.file.name), [
      'gallery-1.png',
      'gallery-2.png',
    ]);
    expect(room.client.resizeRequests, hasLength(2));
    expect(
      room.client.resizeRequests.every(
        (request) => request.maxDimension == 1600,
      ),
      isTrue,
    );
    expect(room.sentFiles.every((sent) => sent.maxDimension == null), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows upload errors on the chat after the dialog is disposed', (
    tester,
  ) async {
    final room = _TestRoom()..sendError = StateError('Upload failed');
    final state = await _openDialog(tester, room, [_photo('camera.png')]);
    await tester.tap(find.text('Send'));
    await _dismissWhileConfigIsPending(tester);
    expect(state.mounted, isFalse);

    room.client.config.complete(MediaConfig(mUploadSize: 1000000));
    await tester.pumpAndSettle();

    expect(room.sentFiles, hasLength(1));
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Upload failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compresses an oversized original before checking and sending', (
    tester,
  ) async {
    final room = _TestRoom();
    final original = Uint8List.fromList([
      ..._imageBytes,
      ...List<int>.filled(1000, 0),
    ]);
    room.client.compressedBytes = _imageBytes;
    await _openDialog(tester, room, [
      XFile.fromData(original, name: 'large-photo.png', mimeType: 'image/png'),
    ]);
    await tester.tap(find.text('Send'));
    await _dismissWhileConfigIsPending(tester);

    room.client.config.complete(MediaConfig(mUploadSize: _imageBytes.length));
    await tester.pumpAndSettle();

    expect(room.client.resizeRequests.single.bytes, original);
    expect(room.sentFiles.single.file.bytes, _imageBytes);
    expect(room.sentFiles.single.maxDimension, isNull);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the size error when an uncompressed photo is too large', (
    tester,
  ) async {
    final room = _TestRoom();
    await _openDialog(tester, room, [_photo('original.png')]);
    await tester.tap(find.byType(Switch));
    await tester.tap(find.text('Send'));
    await _dismissWhileConfigIsPending(tester);

    room.client.config.complete(MediaConfig(mUploadSize: 1));
    await tester.pumpAndSettle();

    expect(room.client.resizeRequests, isEmpty);
    expect(room.sentFiles, isEmpty);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
