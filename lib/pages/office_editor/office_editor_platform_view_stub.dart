// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:material_ui/material_ui.dart';

typedef OfficeBridgeSend = void Function(Map<String, Object?> message);

class OfficeEditorPlatformView extends StatelessWidget {
  final ValueChanged<OfficeBridgeSend> onSendReady;
  final ValueChanged<Map<String, Object?>> onMessage;

  const OfficeEditorPlatformView({
    required this.onSendReady,
    required this.onMessage,
    super.key,
  });

  @override
  Widget build(BuildContext context) => const Center(
    child: Text('Embedded Office is not supported on this platform.'),
  );
}
