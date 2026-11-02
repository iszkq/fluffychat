// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:io';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/qr_login/qr_login_payload.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_code_scanner_plus/qr_code_scanner_plus.dart';

class QrScannerModal extends StatefulWidget {
  final void Function(String) onScan;
  final void Function(QrLoginPayload)? onLoginScan;
  const QrScannerModal({required this.onScan, this.onLoginScan, super.key});

  @override
  QrScannerModalState createState() => QrScannerModalState();
}

class QrScannerModalState extends State<QrScannerModal> {
  final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');
  QRViewController? controller;
  StreamSubscription<Barcode>? _subscription;
  bool _handled = false;
  bool _invalidShown = false;

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    // QRView owns and disposes its platform controller.
    super.dispose();
  }

  @override
  void reassemble() {
    super.reassemble();
    if (Platform.isAndroid) {
      controller?.pauseCamera();
    } else if (Platform.isIOS) {
      controller?.resumeCamera();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_outlined),
          onPressed: Navigator.of(context).pop,
          tooltip: L10n.of(context).close,
        ),
        title: Text(L10n.of(context).scanQrCode),
      ),
      body: Stack(
        children: [
          QRView(
            key: qrKey,
            onQRViewCreated: _onQRViewCreated,
            overlay: QrScannerOverlayShape(
              borderColor: Theme.of(context).colorScheme.primary,
              borderRadius: 10,
              borderLength: 30,
              borderWidth: 8,
            ),
          ),
        ],
      ),
    );
  }

  void _onQRViewCreated(QRViewController controller) {
    this.controller = controller;
    // Workaround for QR Scanner is started in Pause mode
    // https://github.com/juliuscanute/qr_code_scanner/issues/538#issuecomment-1133883828
    if (Platform.isAndroid) {
      controller.pauseCamera();
    }
    controller.resumeCamera();
    unawaited(_subscription?.cancel());
    _subscription = controller.scannedDataStream.listen((scanData) {
      if (!mounted || _handled) return;
      QrLoginPayload? login;
      try {
        login = QrLoginPayload.fromScan(
          text: scanData.code,
          rawBytes: scanData.rawBytes,
        );
      } on FormatException {
        if (!_invalidShown) {
          _invalidShown = true;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.of(context).qrLoginInvalidCode)),
          );
        }
        return;
      }
      final onLogin = widget.onLoginScan;
      final text = scanData.code;
      if (login != null && onLogin != null) {
        _handled = true;
        unawaited(_subscription?.cancel());
        Navigator.of(context).pop();
        onLogin(login);
      } else if (login == null && text != null && text.isNotEmpty) {
        _handled = true;
        unawaited(_subscription?.cancel());
        Navigator.of(context).pop();
        widget.onScan(text);
      }
    });
  }
}
