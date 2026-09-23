<!--
SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# iOS 侧载版 Matrix 推送

这套方案不依赖你的 FluffyChat iOS 安装包拥有 Apple Push Notifications
权限。主 App 不再声明 APNs entitlement；FluffyChat 把 Matrix Pusher 注册到仓库中的 Cloudflare Pages Function，
Function 再把通知转发到 ntfy；ntfy iOS App 负责接收系统通知。

```text
Matrix Homeserver
    ↓  Matrix Push Gateway
Cloudflare Pages Function: /_matrix/push/v1/notify
    ↓  ntfy HTTP API
ntfy iOS App
    ↓  点击通知
你的 FluffyChat: im.fluffychat://room/...
```

## 1. 配置 ntfy

在 ntfy iOS App 中订阅一个足够随机的主题。不要使用 `fluffychat`、房间名或
其他容易猜到的主题名，因为知道主题名的人可以向你的 iPhone 发送通知。

PowerShell 可以生成一个主题名：

```powershell
"fluffychat-" + [guid]::NewGuid().ToString('N')
```

例如：

```text
fluffychat-8f2d1c3b8a9e4f0d9e6a2c1b7d5f4a10
```

在 ntfy App 中订阅这个完整主题，并允许 ntfy 发送通知。

默认情况下，仓库 Function 会把通知发送到 `https://ntfy.sh`。如果你自托管
ntfy，可以在 Cloudflare Pages 项目中设置普通环境变量：

```text
NTFY_BASE_URL=https://你的-ntfy-域名
```

不要在公开仓库中提交 ntfy 管理密钥。这个方案只依赖随机主题作为接收地址。

## 2. 部署 Matrix 推送网关

仓库已经包含以下 Pages Function：

```text
functions/_matrix/push/v1/notify.js
```

部署后，推送网关地址为：

```text
https://你的站点域名/_matrix/push/v1/notify
```

它同时支持：

- Android 的 Firebase 推送器；
- iOS 侧载版的 `ntfy:<主题>` 推送器。

Android 仍然需要 `FIREBASE_SERVICE_ACCOUNT`；只有 iOS ntfy 推送器时，不需要
配置 Firebase 服务账号。

## 3. 构建 iOS 侧载版

在构建时把 ntfy 主题和 Matrix 推送网关地址传给 Flutter。两个值必须和上面的
配置完全一致：

```sh
flutter build ios --release \
  --dart-define=NTFY_TOPIC=fluffychat-8f2d1c3b8a9e4f0d9e6a2c1b7d5f4a10 \
  --dart-define=PUSH_NOTIFICATIONS_GATEWAY_URL=https://你的站点域名/_matrix/push/v1/notify
```

如果使用仓库脚本：

```sh
NTFY_TOPIC=fluffychat-8f2d1c3b8a9e4f0d9e6a2c1b7d5f4a10 \
PUSH_NOTIFICATIONS_GATEWAY_URL=https://你的站点域名/_matrix/push/v1/notify \
./scripts/release-ios-testflight.sh
```

也可以在 GitHub Actions 的 `Build Mobile Packages` 中使用：

- 仓库 Secret `NTFY_TOPIC`：同一个随机主题；
- `push_notifications_gateway_url`：你的 Pages Function 地址；
- 其他两个参数按项目实际部署地址填写。

工作流会把这两个参数写入 iOS IPA。Android 构建仍按原来的 Firebase 流程运行。

脚本最后会生成 Xcode archive；之后可以使用你的侧载工具签名安装。这个推送
方案不要求 FluffyChat 本身拥有 APNs entitlement，但 ntfy App 必须正常安装、
订阅主题并允许通知。

## 4. 点击通知打开房间

Function 会为每条通知生成类似下面的点击链接：

```text
im.fluffychat://room/编码后的房间ID?event=编码后的事件ID&client=客户端名称
```

点击 ntfy 通知时，iOS 会启动 FluffyChat；FluffyChat 会打开对应房间，并尽量
定位到触发通知的事件。FluffyChat 被后台挂起或从多任务界面关闭，不影响服务端
发送通知；但如果 FluffyChat 已被卸载，就没有 App 可以接收这个链接。

## 5. 测试

先在 ntfy App 中确认主题已订阅，然后在 Matrix 账号的另一台设备发送消息。
检查顺序如下：

1. Cloudflare Pages Function 的请求日志中出现 `/_matrix/push/v1/notify`；
2. ntfy App 收到通知；
3. 点击通知后打开 FluffyChat；
4. FluffyChat 进入正确房间；
5. 多账号或多客户端时确认 `client` 参数没有跳到错误账号。

也可以直接模拟 Matrix Push Gateway 请求：

```powershell
$body = @{
  notification = @{
    room_id = '!test:example.org'
    event_id = '$test:example.org'
    room_name = '测试房间'
    sender_display_name = '测试用户'
    counts = @{ unread = 1 }
    devices = @(
      @{
        pushkey = 'ntfy:你的主题名'
        app_id = 'chat.fluffy.fluffychat.x'
        data = @{ client_name = 'FluffyChat' }
      }
    )
  }
} | ConvertTo-Json -Depth 8

Invoke-RestMethod `
  -Method Post `
  -Uri 'https://你的站点域名/_matrix/push/v1/notify' `
  -ContentType 'application/json' `
  -Body $body
```

## 注意事项

- ntfy 主题相当于一个公开通知地址，必须使用高熵随机值；
- 当前通知只发送房间名、发送者、未读数、房间 ID 和事件 ID，不发送消息正文；
- 端到端加密房间不需要让中转服务解密消息；
- `event_id_only` 是本方案的推荐 Pusher 格式；
- iOS 的 ntfy App 不要从系统多任务界面强制退出，否则系统可能暂时停止其后台
  通知接收；
- 如果只重新安装 FluffyChat，不需要重新订阅 ntfy，只要继续使用相同的
  `NTFY_TOPIC` 重新构建即可。
