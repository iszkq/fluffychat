// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

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
  late final WebViewController _controller;
  bool _bridgeReady = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'FluffyOfficeBridge',
        onMessageReceived: (message) {
          final decoded = jsonDecode(message.message);
          if (decoded is Map) {
            widget.onMessage(decoded.cast<String, Object?>());
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (_bridgeReady) return;
            _bridgeReady = true;
            widget.onSendReady(_send);
          },
        ),
      );
    _loadHost();
  }

  Future<void> _loadHost() async {
    final html = await rootBundle.loadString('assets/office/office_host.html');
    await _controller.loadHtmlString(
      html,
      baseUrl: 'https://app.fluffychat.local/',
    );
  }

  void _send(Map<String, Object?> message) {
    final json = jsonEncode(message);
    _controller.runJavaScript(
      'window.fluffyOfficeReceive(${jsonEncode(json)});',
    );
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
