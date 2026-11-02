// SPDX-FileCopyrightText: 2026 Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';

import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/utils/qr_login/msc4108_channel.dart';
import 'package:fluffychat/utils/qr_login/qr_login_existing_device.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/adaptive_dialog_action.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

enum _Stage {
  consent,
  connecting,
  unlock,
  check,
  authorize,
  waiting,
  sharing,
  done,
  error,
}

class QrLoginDialog extends StatefulWidget {
  final QrLoginExistingDevice flow;
  final Future<bool> Function(Uri uri)? openAuthorization;

  const QrLoginDialog({super.key, required this.flow, this.openAuthorization});

  static Future<void> show(BuildContext context, QrLoginExistingDevice flow) =>
      showAdaptiveDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => QrLoginDialog(flow: flow),
      );

  @override
  State<QrLoginDialog> createState() => _QrLoginDialogState();
}

class _QrLoginDialogState extends State<QrLoginDialog> {
  static const _contentWidth = 320.0;
  static const _gap = 16.0;
  _Stage _stage = _Stage.consent;
  Completer<bool>? _decision;
  Timer? _timer;
  String? _code;
  String? _deviceId;
  String? _error;
  Uri? _authorization;
  bool _opening = false;
  final _recovery = TextEditingController();
  bool _unlocking = false;
  bool _unlockFailed = false;

  @override
  void dispose() {
    _timer?.cancel();
    widget.flow.cancel();
    _recovery.clear();
    _recovery.dispose();
    if (_decision?.isCompleted == false) _decision!.complete(false);
    super.dispose();
  }

  void _decide(bool value) {
    final decision = _decision;
    if (decision != null && !decision.isCompleted) decision.complete(value);
  }

  Future<void> _start() async {
    if (_stage != _Stage.consent) return;
    setState(() => _stage = _Stage.connecting);
    _timer = Timer(const Duration(minutes: 5), () {
      widget.flow.cancel();
      _decide(false);
      if (mounted) {
        setState(() {
          _error = 'expired';
          _stage = _Stage.error;
        });
      }
    });
    try {
      await widget.flow.run(
        unlockSecrets: () async {
          if (!mounted || _stage == _Stage.error) return false;
          final decision = _decision = Completer<bool>();
          setState(() => _stage = _Stage.unlock);
          final unlocked = await decision.future;
          if (mounted && _stage != _Stage.error) {
            setState(() => _stage = _Stage.connecting);
          }
          return unlocked;
        },
        confirmCode: (code) async {
          if (!mounted || _stage == _Stage.error) return false;
          final decision = _decision = Completer<bool>();
          setState(() {
            _code = code;
            _stage = _Stage.check;
          });
          final confirmed = await decision.future;
          if (mounted && _stage != _Stage.error) {
            setState(() => _stage = _Stage.connecting);
          }
          return confirmed;
        },
        authorize: (uri, deviceId) {
          if (!mounted || _stage == _Stage.error) return Future.value(false);
          final decision = _decision = Completer<bool>();
          setState(() {
            _authorization = uri;
            _deviceId = deviceId;
            _stage = _Stage.authorize;
          });
          return decision.future;
        },
        onSharingSecrets: () {
          if (mounted) setState(() => _stage = _Stage.sharing);
        },
      );
      if (mounted && _stage != _Stage.error) {
        setState(() => _stage = _Stage.done);
      }
    } catch (error) {
      if (mounted && _stage != _Stage.error) {
        setState(() {
          _error = error is QrLoginException ? error.reason : 'network_error';
          _stage = _Stage.error;
        });
      }
    } finally {
      _timer?.cancel();
    }
  }

  Future<void> _unlock() async {
    if (_unlocking || _recovery.text.trim().isEmpty) return;
    setState(() {
      _unlocking = true;
      _unlockFailed = false;
    });
    try {
      await widget.flow.account.unlockSecrets(_recovery.text.trim());
      if (mounted && _stage == _Stage.unlock) {
        _recovery.clear();
        _decide(true);
      }
    } catch (_) {
      if (mounted && _stage == _Stage.unlock) {
        setState(() => _unlockFailed = true);
      }
    } finally {
      if (mounted) setState(() => _unlocking = false);
    }
  }

  Future<void> _openAuthorization() async {
    if (_opening || _authorization == null) return;
    setState(() => _opening = true);
    try {
      final opened =
          await (widget.openAuthorization?.call(_authorization!) ??
              launchUrl(_authorization!, mode: LaunchMode.externalApplication));
      if (!mounted || ![_Stage.authorize, _Stage.waiting].contains(_stage)) {
        return;
      }
      if (!opened) {
        setState(() => _error = 'browser_unavailable');
        return;
      }
      setState(() {
        _error = null;
        _stage = _Stage.waiting;
      });
      _decide(true);
    } catch (_) {
      if (mounted && [_Stage.authorize, _Stage.waiting].contains(_stage)) {
        setState(() => _error = 'browser_unavailable');
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  String _errorText(L10n l10n) => switch (_error) {
    'keys_locked' => l10n.qrLoginKeysLocked,
    'expired' || 'authorization_expired' => l10n.qrLoginExpired,
    'user_cancelled' || 'user_declined' => l10n.qrLoginCancelled,
    'unsupported_protocol' => l10n.qrLoginUnsupported,
    'device_not_found' || 'account_changed' => l10n.qrLoginWrongAccount,
    'browser_unavailable' => l10n.qrLoginBrowserFailed,
    'insecure_channel_detected' ||
    'authorization_uri_mismatch' ||
    'device_already_exists' ||
    'unexpected_message_received' => l10n.qrLoginSecurityError,
    _ => l10n.qrLoginNetworkError,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final busy = [
      _Stage.connecting,
      _Stage.waiting,
      _Stage.sharing,
    ].contains(_stage);
    final message = switch (_stage) {
      _Stage.consent => l10n.qrLoginConsent,
      _Stage.connecting => l10n.qrLoginConnecting,
      _Stage.unlock => l10n.qrLoginUnlockHint,
      _Stage.check => l10n.qrLoginCompareCode,
      _Stage.authorize => l10n.qrLoginAuthorizationHint,
      _Stage.waiting => l10n.qrLoginWaiting,
      _Stage.sharing => l10n.qrLoginSharing,
      _Stage.done => l10n.qrLoginSuccess,
      _Stage.error => _errorText(l10n),
    };
    return AlertDialog.adaptive(
      title: Text(l10n.qrLoginTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _contentWidth),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(widget.flow.account.userId),
              const SizedBox(height: _gap),
              Text(message),
              if (_stage == _Stage.unlock) ...[
                const SizedBox(height: _gap),
                TextField(
                  controller: _recovery,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.visiblePassword,
                  decoration: InputDecoration(
                    labelText: l10n.passphraseOrKey,
                    errorText: _unlockFailed
                        ? l10n.incorrectPassphraseOrKey
                        : null,
                  ),
                  onSubmitted: (_) => _unlock(),
                ),
                if (_unlocking) const LinearProgressIndicator(),
              ],
              if (_stage == _Stage.check) ...[
                const SizedBox(height: _gap),
                Center(
                  child: SelectableText(
                    _code!,
                    style: theme.textTheme.displaySmall,
                  ),
                ),
              ],
              if ([_Stage.authorize, _Stage.waiting].contains(_stage)) ...[
                const SizedBox(height: _gap),
                Text(_authorization!.host, style: theme.textTheme.titleMedium),
                Text(l10n.qrLoginDevice(_deviceId!)),
              ],
              if (_error != null && _stage != _Stage.error) ...[
                const SizedBox(height: _gap),
                Text(
                  _errorText(l10n),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              if (busy) ...[
                const SizedBox(height: _gap),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
      ),
      actions: [
        AdaptiveDialogAction(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            [_Stage.done, _Stage.error].contains(_stage)
                ? l10n.close
                : l10n.cancel,
          ),
        ),
        if (_stage == _Stage.consent)
          AdaptiveDialogAction(
            onPressed: _start,
            child: Text(l10n.qrLoginContinue),
          ),
        if (_stage == _Stage.unlock)
          AdaptiveDialogAction(
            onPressed: _unlocking ? null : _unlock,
            child: Text(l10n.unlock),
          ),
        if (_stage == _Stage.check)
          AdaptiveDialogAction(
            onPressed: () => _decide(true),
            child: Text(l10n.qrLoginCodesMatch),
          ),
        if ([_Stage.authorize, _Stage.waiting].contains(_stage))
          AdaptiveDialogAction(
            onPressed: _opening ? null : _openAuthorization,
            child: Text(l10n.qrLoginOpenAuthorization),
          ),
      ],
    );
  }
}
