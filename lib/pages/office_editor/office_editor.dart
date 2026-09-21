// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/pages/chat/trust_user_key_dialog.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:uuid/uuid.dart';

import 'office_editor_platform_view.dart';

const _officeExtensions = {'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'pdf'};
const officeEditMetadataKey = 'xyz.flchat.office_edit';

bool isOfficeDocument(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0) return false;
  return _officeExtensions.contains(fileName.substring(dot + 1).toLowerCase());
}

Future<void> openOfficeDocument(BuildContext context, Event event) async {
  final result = await event.getFile(context);
  final file = result.asValue?.value;
  if (file == null || !context.mounted) return;
  // Keep the editor above the responsive room shell. On wide landscape
  // phones the room shell switches to its two-column layout; a route pushed
  // onto that nested navigator would otherwise be disposed during rotation.
  await Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => OfficeEditorPage(
        file: file,
        room: event.room,
        sourceEvent: event,
      ),
    ),
  );
}

enum _ExportAction { download, send }

class OfficeEditorPage extends StatefulWidget {
  final MatrixFile file;
  final Room room;
  final Event sourceEvent;

  const OfficeEditorPage({
    required this.file,
    required this.room,
    required this.sourceEvent,
    super.key,
  });

  @override
  State<OfficeEditorPage> createState() => _OfficeEditorPageState();
}

class _OfficeEditorPageState extends State<OfficeEditorPage> {
  static const _sourceChunkSize = 192 * 1024;

  final String _requestId = const Uuid().v4();
  OfficeBridgeSend? _send;
  Timer? _startupTimeout;
  Timer? _saveTimeout;
  Completer<void>? _chunkAcknowledged;
  int? _waitingForChunk;
  bool _sourceStarted = false;
  bool _opened = false;
  bool _dirty = false;
  bool _saving = false;
  String _status = '';
  String? _error;
  _ExportAction? _pendingAction;
  BytesBuilder? _savedBytes;
  int? _savedByteLength;
  int? _savedChunkCount;
  int _savedChunks = 0;
  String? _savedFileName;
  String? _savedMimeType;
  String? _activeSaveId;

  _OfficeStrings get _strings => _OfficeStrings.of(context);

  bool get _sourceBelongsToCurrentUser =>
      widget.sourceEvent.senderId == widget.room.client.userID;

  bool get _useMobilePresentation =>
      PlatformInfos.isMobile || MediaQuery.sizeOf(context).shortestSide < 600;

  void _onSendReady(OfficeBridgeSend send) {
    _send = send;
    final locale = Localizations.localeOf(context);
    send({
      'type': 'fluffy-office-init',
      'requestId': _requestId,
      'editorUrl': AppSettings.officeEditorUrl.value.replaceFirst(
        RegExp(r'/+$'),
        '',
      ),
      'parentOrigin': kIsWeb ? Uri.base.origin : 'https://app.fluffychat.local',
      'editing': true,
      'lang': locale.toLanguageTag(),
      'theme': Theme.of(context).brightness == Brightness.dark
          ? 'dark'
          : 'light',
      'mobile': _useMobilePresentation,
    });
    _startupTimeout?.cancel();
    _startupTimeout = Timer(const Duration(seconds: 45), () {
      if (!_sourceStarted) _showError(_strings.serviceUnavailable);
    });
  }

  void _onMessage(Map<String, Object?> message) {
    if (message['requestId'] != _requestId) return;
    switch (message['type']) {
      case 'xinghuo-office-ready':
        _startupTimeout?.cancel();
        if (!_sourceStarted) unawaited(_transferSource());
      case 'xinghuo-office-source-chunk-received':
        final chunkIndex = message['chunkIndex'];
        if (chunkIndex == _waitingForChunk) {
          _chunkAcknowledged?.complete();
        }
      case 'xinghuo-office-source-received':
        _setStatus(_strings.opening);
      case 'xinghuo-office-opened':
        if (!mounted) return;
        setState(() {
          _opened = true;
          _status = '';
          _error = null;
        });
      case 'xinghuo-office-dirty':
        if (!mounted) return;
        setState(() => _dirty = message['dirty'] == true);
      case 'xinghuo-office-saving':
        if (!mounted) return;
        setState(() {
          _saving = true;
          _status = _strings.exporting;
        });
      case 'fluffy-office-saved-begin':
        _beginSavedFile(message);
      case 'fluffy-office-saved-chunk':
        _appendSavedChunk(message);
      case 'fluffy-office-saved-end':
        unawaited(_finishSavedFile(message));
      case 'xinghuo-office-error':
        final saveId = message['saveId'];
        if (saveId != null && saveId != _activeSaveId) return;
        _showError(
          message['message'] is String
              ? message['message']! as String
              : _strings.failed,
        );
    }
  }

  Future<void> _transferSource() async {
    _sourceStarted = true;
    _setStatus(_strings.transferring);
    final bytes = widget.file.bytes;
    final chunkCount = (bytes.length / _sourceChunkSize).ceil();
    final extension = widget.file.name.contains('.')
        ? widget.file.name.split('.').last.toLowerCase()
        : null;
    _send!({
      'type': 'xinghuo-office-source-begin',
      'requestId': _requestId,
      'fileName': widget.file.name,
      'fileType': extension,
      'mimeType': widget.file.mimeType,
      'byteLength': bytes.length,
      'chunkCount': chunkCount,
      'chunkSize': _sourceChunkSize,
    });

    try {
      for (var index = 0; index < chunkCount; index++) {
        final end = min((index + 1) * _sourceChunkSize, bytes.length);
        _waitingForChunk = index;
        _chunkAcknowledged = Completer<void>();
        _send!({
          'type': 'xinghuo-office-source-chunk',
          'requestId': _requestId,
          'chunkIndex': index,
          'chunkData': base64Encode(
            Uint8List.sublistView(bytes, index * _sourceChunkSize, end),
          ),
        });
        await _chunkAcknowledged!.future.timeout(const Duration(seconds: 30));
        if (mounted) {
          setState(() {
            _status = _strings.transferringProgress(index + 1, chunkCount);
          });
        }
      }
      _send!({'type': 'xinghuo-office-source-end', 'requestId': _requestId});
    } catch (error, stackTrace) {
      Logs().w(
        'Unable to transfer document to Office editor',
        error,
        stackTrace,
      );
      _showError(_strings.failed);
    } finally {
      _waitingForChunk = null;
      _chunkAcknowledged = null;
    }
  }

  void _beginSavedFile(Map<String, Object?> message) {
    if (!_matchesActiveSave(message)) return;
    _savedBytes = BytesBuilder(copy: false);
    _savedByteLength = message['byteLength'] as int?;
    _savedChunkCount = message['chunkCount'] as int?;
    _savedChunks = 0;
    _savedFileName = message['fileName'] as String?;
    _savedMimeType = message['mimeType'] as String?;
  }

  void _appendSavedChunk(Map<String, Object?> message) {
    if (!_matchesActiveSave(message)) return;
    final chunk = message['chunkData'];
    if (_savedBytes == null || chunk is! String) return;
    if (message['chunkIndex'] != _savedChunks) {
      _showError(_strings.incompleteExport);
      return;
    }
    try {
      _savedBytes!.add(base64Decode(chunk));
      _savedChunks++;
    } on FormatException {
      _showError(_strings.incompleteExport);
    }
  }

  bool _matchesActiveSave(Map<String, Object?> message) {
    final saveId = message['saveId'];
    return _activeSaveId != null &&
        (saveId == null || saveId == _activeSaveId);
  }

  Future<void> _finishSavedFile(Map<String, Object?> message) async {
    if (!_matchesActiveSave(message)) return;
    _saveTimeout?.cancel();
    final builder = _savedBytes;
    final action = _pendingAction;
    _savedBytes = null;
    _pendingAction = null;
    if (builder == null || action == null) {
      _showError(_strings.failed);
      return;
    }
    final bytes = builder.takeBytes();
    if (bytes.length != _savedByteLength || _savedChunks != _savedChunkCount) {
      _showError(_strings.incompleteExport);
      return;
    }
    var file = MatrixFile(
      bytes: bytes,
      name: _savedFileName ?? widget.file.name,
      mimeType: _savedMimeType ?? widget.file.mimeType,
    );
    try {
      if (action == _ExportAction.download) {
        await file.save(context);
      } else {
        final updatedAt = DateTime.now();
        final editorId = widget.room.client.userID;
        final editorName = _editorName(editorId);
        if (!_sourceBelongsToCurrentUser) {
          file = MatrixFile(
            bytes: bytes,
            name: _editedCopyName(widget.file.name, editorName, updatedAt),
            mimeType: _savedMimeType ?? widget.file.mimeType,
          );
        } else if (file.name != widget.file.name) {
          file = MatrixFile(
            bytes: bytes,
            name: widget.file.name,
            mimeType: file.mimeType,
          );
        }
        await widget.room.sendFileEvent(
          file,
          editEventId: _sourceBelongsToCurrentUser
              ? widget.sourceEvent.eventId
              : null,
          extraContent: {
            officeEditMetadataKey: {
              'editor': editorName,
              if (editorId != null) 'editor_id': editorId,
              'updated_at': updatedAt.toUtc().toIso8601String(),
              'source_event_id': widget.sourceEvent.eventId,
            },
          },
        );
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(
            SnackBar(
              content: Text(
                _sourceBelongsToCurrentUser
                    ? _strings.updatedOriginal
                    : _strings.sentCopy,
              ),
            ),
          );
        }
      }
      if (mounted) {
        setState(() {
          _saving = false;
          _dirty = false;
          _status = '';
          _activeSaveId = null;
        });
      }
    } catch (error, stackTrace) {
      Logs().w('Unable to store edited Office document', error, stackTrace);
      _showError(error.toString());
    }
  }

  Future<void> _export(_ExportAction action) async {
    if (!_opened || _saving || _send == null) return;
    if (action == _ExportAction.send) {
      final proceed = await showTrustUserInRoomDialog(context, widget.room);
      if (!mounted || !proceed) return;
    }
    final saveId = const Uuid().v4();
    setState(() {
      _pendingAction = action;
      _activeSaveId = saveId;
      _saving = true;
      _status = _strings.exporting;
      _error = null;
    });
    _send!({
      'type': 'xinghuo-office-save',
      'requestId': _requestId,
      'saveId': saveId,
      'fileName': widget.file.name,
      'mimeType': widget.file.mimeType,
      'mobile': _useMobilePresentation,
    });
    _saveTimeout?.cancel();
    _saveTimeout = Timer(const Duration(minutes: 2), () {
      if (_activeSaveId == saveId) _showError(_strings.saveTimedOut);
    });
  }

  String _editorName(String? userId) {
    if (userId == null) return _strings.unknownEditor;
    final displayName = widget.room
        .unsafeGetUserFromMemoryOrFallback(userId)
        .calcDisplayname()
        .trim();
    if (displayName.isNotEmpty) return displayName;
    return userId.split(':').first.replaceFirst('@', '');
  }

  void _setStatus(String value) {
    if (!mounted) return;
    setState(() {
      _status = value;
      _error = null;
    });
  }

  void _showError(String value) {
    if (!mounted) return;
    _saveTimeout?.cancel();
    setState(() {
      _saving = false;
      _pendingAction = null;
      _activeSaveId = null;
      _savedBytes = null;
      _status = '';
      _error = value;
    });
  }

  @override
  void dispose() {
    _startupTimeout?.cancel();
    _saveTimeout?.cancel();
    if (!(_chunkAcknowledged?.isCompleted ?? true)) {
      _chunkAcknowledged!.completeError(StateError('Office editor closed'));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).shortestSide < 600;
    final canExport = _opened && !_saving;
    final actionSurface = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.file.name, overflow: TextOverflow.ellipsis),
            if (_dirty)
              Text(
                _strings.unsaved,
                style: Theme.of(context).textTheme.labelSmall,
              ),
          ],
        ),
        actions: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: actionSurface.withAlpha(210),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _OfficeActionButton(
                    tooltip: _strings.downloadCopy,
                    icon: Icons.download_outlined,
                    onPressed: canExport
                        ? () => _export(_ExportAction.download)
                        : null,
                  ),
                  if (compact)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 28,
                          child: VerticalDivider(
                            width: 1,
                            color: Theme.of(context)
                                .colorScheme
                                .outlineVariant,
                          ),
                        ),
                        _OfficeActionButton(
                          tooltip: _sourceBelongsToCurrentUser
                              ? _strings.saveChanges
                              : _strings.sendEditedCopy,
                          icon: _sourceBelongsToCurrentUser
                              ? Icons.save_outlined
                              : Icons.send_outlined,
                          onPressed: canExport
                              ? () => _export(_ExportAction.send)
                              : null,
                        ),
                      ],
                    )
                  else
                    TextButton.icon(
                      onPressed: canExport
                          ? () => _export(_ExportAction.send)
                          : null,
                      icon: Icon(
                        _sourceBelongsToCurrentUser
                            ? Icons.save_outlined
                            : Icons.send_outlined,
                      ),
                      label: Text(
                        _sourceBelongsToCurrentUser
                            ? _strings.saveChanges
                            : _strings.sendEditedCopy,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          OfficeEditorPlatformView(
            onSendReady: _onSendReady,
            onMessage: _onMessage,
          ),
          if (_status.isNotEmpty)
            ColoredBox(
              color: Theme.of(context).colorScheme.surface.withAlpha(220),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator.adaptive(),
                    const SizedBox(height: 16),
                    Text(_status),
                  ],
                ),
              ),
            ),
          if (_error != null)
            ColoredBox(
              color: Theme.of(context).colorScheme.surface.withAlpha(240),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 48,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(height: 12),
                      Text(_strings.failed, textAlign: TextAlign.center),
                      if (_error != _strings.failed) ...[
                        const SizedBox(height: 8),
                        Text(_error!, textAlign: TextAlign.center),
                      ],
                      const SizedBox(height: 16),
                      TextButton.icon(
                        onPressed: () {
                          if (_opened) {
                            setState(() => _error = null);
                          } else {
                            Navigator.of(context).pop();
                          }
                        },
                        icon: Icon(
                          _opened ? Icons.arrow_back : Icons.close,
                        ),
                        label: Text(
                          _opened
                              ? _strings.backToDocument
                              : _strings.close,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _OfficeActionButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  const _OfficeActionButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(11);
    final colorScheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        enabled: enabled,
        child: Material(
          color: enabled
              ? colorScheme.surface.withAlpha(220)
              : Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            onTap: onPressed,
            borderRadius: radius,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                icon,
                size: 22,
                color: enabled
                    ? colorScheme.onSurface
                    : colorScheme.onSurface.withAlpha(90),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OfficeStrings {
  final bool zh;

  const _OfficeStrings(this.zh);

  factory _OfficeStrings.of(BuildContext context) =>
      _OfficeStrings(Localizations.localeOf(context).languageCode == 'zh');

  String get transferring => zh ? '正在传输文档…' : 'Transferring document…';
  String transferringProgress(int current, int total) => zh
      ? '正在传输文档（$current/$total）…'
      : 'Transferring document ($current/$total)…';
  String get opening => zh ? '正在打开文档…' : 'Opening document…';
  String get exporting => zh ? '正在生成编辑后的文档…' : 'Exporting edited document…';
  String get failed =>
      zh ? '无法打开或处理此文档' : 'Unable to open or process this document';
  String get serviceUnavailable => zh
      ? '无法连接 Office 编辑服务，请检查服务地址和 HTTPS 证书'
      : 'Unable to reach the Office editor. Check its URL and HTTPS certificate.';
  String get incompleteExport =>
      zh ? '导出的文档数据不完整' : 'The exported document is incomplete';
  String get saveTimedOut => zh
      ? 'Office 编辑服务未在两分钟内返回文档，请返回后重试'
      : 'The Office editor did not return the document within two minutes. Please try again.';
  String get unsaved => zh ? '有未发送的修改' : 'Unsaved changes';
  String get downloadCopy => zh ? '下载编辑后的副本' : 'Download edited copy';
  String get saveChanges => zh ? '保存并替换原文件' : 'Save and replace original';
  String get sendEditedCopy => zh ? '发送编辑后的副本' : 'Send edited copy';
  String get updatedOriginal =>
      zh ? '原文件已更新' : 'The original file was updated';
  String get sentCopy => zh ? '编辑后的副本已发送' : 'Edited copy sent';
  String get unknownEditor => zh ? '编辑者' : 'Editor';
  String get backToDocument => zh ? '返回文档' : 'Back to document';
  String get close => zh ? '关闭' : 'Close';
}

String _editedCopyName(
  String originalName,
  String editorName,
  DateTime updatedAt,
) {
  final dot = originalName.lastIndexOf('.');
  final rawBase = dot > 0 ? originalName.substring(0, dot) : originalName;
  final extension = dot > 0 ? originalName.substring(dot) : '';
  final safeBase = _safeFileNamePart(rawBase, fallback: 'document');
  final safeEditor = _safeFileNamePart(editorName, fallback: 'editor');
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  final stamp = '${updatedAt.year.toString().padLeft(4, '0')}-'
      '${twoDigits(updatedAt.month)}-${twoDigits(updatedAt.day)}_'
      '${twoDigits(updatedAt.hour)}-${twoDigits(updatedAt.minute)}';
  final suffix = '_${safeEditor}_$stamp';
  final remainingRunes = 180 - suffix.runes.length - extension.runes.length;
  final maxBaseRunes = remainingRunes > 1 ? remainingRunes : 1;
  final clippedBase = String.fromCharCodes(safeBase.runes.take(maxBaseRunes));
  return '$clippedBase$suffix$extension';
}

String _safeFileNamePart(String value, {required String fallback}) {
  final safe = value
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  return safe.isEmpty ? fallback : safe;
}
