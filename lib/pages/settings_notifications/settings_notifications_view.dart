// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/settings_notifications/push_rule_extensions.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/push_helper.dart';
import 'package:fluffychat/widgets/layouts/max_width_body.dart';
import 'package:fluffychat/widgets/settings_switch_list_tile.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../utils/localized_exception_extension.dart';
import '../../widgets/matrix.dart';
import 'settings_notifications.dart';

class SettingsNotificationsView extends StatelessWidget {
  final SettingsNotificationsController controller;

  const SettingsNotificationsView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final pushRules = Matrix.of(context).client.globalPushRules;
    final pushCategories = [
      if (pushRules?.override?.isNotEmpty ?? false)
        (rules: pushRules?.override ?? [], kind: PushRuleKind.override),
      if (pushRules?.content?.isNotEmpty ?? false)
        (rules: pushRules?.content ?? [], kind: PushRuleKind.content),
      if (pushRules?.sender?.isNotEmpty ?? false)
        (rules: pushRules?.sender ?? [], kind: PushRuleKind.sender),
      if (pushRules?.underride?.isNotEmpty ?? false)
        (rules: pushRules?.underride ?? [], kind: PushRuleKind.underride),
    ];
    final pushService = Matrix.of(context).backgroundPush;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !FluffyThemes.isColumnMode(context),
        centerTitle: FluffyThemes.isColumnMode(context),
        title: Text(L10n.of(context).notifications),
      ),
      body: MaxWidthBody(
        child: StreamBuilder(
          stream: Matrix.of(context).client.onSync.stream.where(
            (syncUpdate) =>
                syncUpdate.accountData?.any(
                  (accountData) => accountData.type == 'm.push_rules',
                ) ??
                false,
          ),
          builder: (BuildContext context, _) {
            final theme = Theme.of(context);
            final isChinese =
                Localizations.localeOf(context).languageCode == 'zh';
            final lastReceivedPush =
                lastReceivedPushNotification[Matrix.of(
                  context,
                ).client.clientName];
            return SelectionArea(
              child: Column(
                children: [
                  if (kDebugMode && lastReceivedPush != null)
                    ListTile(
                      title: Text('Last received push notification'),
                      subtitle: Text(lastReceivedPush.toIso8601String()),
                    ),
                  if (kIsWeb)
                    SettingsSwitchListTile.adaptive(
                      title: L10n.of(context).playSoundOnNotification,
                      setting: AppSettings.webNotificationSound,
                    ),
                  if (PlatformInfos.isAndroid)
                    Builder(
                      builder: (context) {
                        final mode = Matrix.of(
                          context,
                        ).androidBackgroundNotificationsMode;
                        return ListTile(
                          leading: const Icon(Icons.sync),
                          title: Text(
                            isChinese
                                ? '安卓后台通知'
                                : 'Android background notifications',
                          ),
                          subtitle: Text(
                            mode ==
                                    AndroidBackgroundNotificationsMode
                                        .persistent
                                ? (isChinese
                                      ? '可靠性更高。通过永久通知保持 Matrix 连接，会增加耗电。'
                                      : 'Most reliable. Keeps Matrix connected with a permanent notification and uses more battery.')
                                : (isChinese
                                      ? '不显示永久通知；安卓关闭应用进程后将停止接收通知。'
                                      : 'No permanent notification. Notifications stop after Android closes the app.'),
                          ),
                          trailing: DropdownButtonHideUnderline(
                            child:
                                DropdownButton<
                                  AndroidBackgroundNotificationsMode
                                >(
                                  value: mode,
                                  items: [
                                    DropdownMenuItem(
                                      value: AndroidBackgroundNotificationsMode
                                          .persistent,
                                      child: Text(
                                        isChinese
                                            ? '永久通知'
                                            : 'Permanent notification',
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: AndroidBackgroundNotificationsMode
                                          .whileAppRunning,
                                      child: Text(
                                        isChinese
                                            ? '应用仍在后台时'
                                            : 'While app is in background',
                                      ),
                                    ),
                                  ],
                                  onChanged: (mode) {
                                    if (mode == null) return;
                                    controller
                                        .setAndroidBackgroundNotificationsMode(
                                          mode,
                                        );
                                  },
                                ),
                          ),
                        );
                      },
                    ),
                  if (pushRules != null)
                    for (final category in pushCategories) ...[
                      ListTile(
                        title: Text(
                          category.kind.localized(L10n.of(context)),
                          style: TextStyle(
                            color: theme.colorScheme.secondary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      for (final rule in category.rules)
                        ListTile(
                          title: Text(rule.getPushRuleName(L10n.of(context))),
                          subtitle: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: rule.getPushRuleDescription(
                                    L10n.of(context),
                                  ),
                                ),
                                const TextSpan(text: ' '),
                                WidgetSpan(
                                  child: InkWell(
                                    onTap: () => controller.editPushRule(
                                      rule,
                                      category.kind,
                                    ),
                                    child: Text(
                                      L10n.of(context).more,
                                      style: TextStyle(
                                        color: theme.colorScheme.primary,
                                        decoration: TextDecoration.underline,
                                        decorationColor:
                                            theme.colorScheme.primary,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          trailing: Switch.adaptive(
                            value: rule.enabled,
                            onChanged: controller.isLoading
                                ? null
                                : rule.ruleId != '.m.rule.master' &&
                                      Matrix.of(
                                        context,
                                      ).client.allPushNotificationsMuted
                                ? null
                                : (_) => controller.togglePushRule(
                                    category.kind,
                                    rule,
                                  ),
                          ),
                        ),
                      Divider(color: theme.dividerColor),
                    ],

                  if (pushService?.firebaseEnabled != true &&
                      !PlatformInfos.isAndroid)
                    ListTile(
                      title: Text(L10n.of(context).buildDoesNotSupportFirebase),
                      leading: Icon(
                        Icons.close,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ListTile(
                    title: Text(
                      L10n.of(context).devices,
                      style: TextStyle(
                        color: theme.colorScheme.secondary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  FutureBuilder<List<Pusher>?>(
                    future: controller.pusherFuture ??= Matrix.of(
                      context,
                    ).client.getPushers(),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        Center(
                          child: Text(
                            snapshot.error!.toLocalizedString(context),
                          ),
                        );
                      }
                      if (snapshot.connectionState != ConnectionState.done) {
                        const Center(
                          child: CircularProgressIndicator.adaptive(
                            strokeWidth: 2,
                          ),
                        );
                      }
                      final pushers = snapshot.data ?? [];
                      if (pushers.isEmpty) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 16.0),
                            child: Text(L10n.of(context).noOtherDevicesFound),
                          ),
                        );
                      }
                      return SelectionArea(
                        child: ListView.builder(
                          physics: const NeverScrollableScrollPhysics(),
                          shrinkWrap: true,
                          itemCount: pushers.length,
                          itemBuilder: (_, i) => ListTile(
                            title: Text(pushers[i].appId),
                            subtitle: Text(pushers[i].data.url.toString()),
                            onTap: () => controller.onPusherTap(pushers[i]),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
