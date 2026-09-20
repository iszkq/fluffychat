// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:material_ui/material_ui.dart';
import 'package:uuid/uuid.dart';
import 'package:web/web.dart' as web;

typedef OfficeBridgeSend = void Function(Map<String, Object?> message);

class OfficeEditorPlatformView extends StatefulWidget {
  final ValueChanged<OfficeBridgeSend> onSendReady;
  final ValueChanged<Map<String, Object?>> onMessage;

  const OfficeEditorPlatformView({
    required this.onSendReady,
    required this.onMessage,
    super.key,
  });

  @override
  State<OfficeEditorPlatformView> createState() =>
      _OfficeEditorPlatformViewState();
}

class _OfficeEditorPlatformViewState extends State<OfficeEditorPlatformView> {
  late final String _viewType;
  late final web.HTMLIFrameElement _iframe;
  StreamSubscription<web.MessageEvent>? _messageSubscription;
  StreamSubscription<web.Event>? _loadSubscription;

  @override
  void initState() {
    super.initState();
    _viewType = 'fluffy-office-${const Uuid().v4()}';
    _iframe = web.HTMLIFrameElement()
      ..src = Uri.base
          .resolve('assets/assets/office/office_host.html')
          .toString()
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.border = '0';

    _messageSubscription = web.window.onMessage.listen((event) {
      if (event.source != _iframe.contentWindow ||
          event.origin != web.window.location.origin) {
        return;
      }
      final raw = event.data.dartify();
      if (raw is! String) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        widget.onMessage(decoded.cast<String, Object?>());
      }
    });
    _loadSubscription = _iframe.onLoad.listen((_) {
      widget.onSendReady(_send);
    });
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (_) => _iframe);
  }

  void _send(Map<String, Object?> message) {
    _iframe.contentWindow?.postMessage(
      jsonEncode(message).toJS,
      web.window.location.origin.toJS,
    );
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _loadSubscription?.cancel();
    _iframe.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
