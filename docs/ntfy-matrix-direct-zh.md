# 自建 ntfy 直接接收 Matrix 推送

此方案只使用已有的 ntfy 容器，不需要新网关容器或域名。
它能让 iOS ntfy App 收到 Matrix 推送，但 ntfy 内置 Matrix 网关把 Matrix JSON
作为消息正文发布，**不会生成 `im.fluffychat://room/...` 点击链接**。
若要点击通知直达 FluffyChat 对应房间，仍需独立的通知转换逻辑。

## 地址

- ntfy 公网地址和容器 `NTFY_BASE_URL`：`https://124.222.193.241:6259`
- Matrix Push Gateway：`https://124.222.193.241:6259/_matrix/push/v1/notify`
- 推送键：`https://124.222.193.241:6259/fluffychat-...`，其中主题由 FluffyChat 生成

ntfy App 继续在 `https://124.222.193.241:6259` 下订阅原来的主题。
这里不使用 `ntfy:<主题>` 推送键；内置网关会拒绝这种格式。

## 一、验证现有 ntfy 的 Matrix 网关

在服务器终端执行以下命令。测试主题随机生成，不使用手机的私人主题：

```sh
TOPIC="fc-check-$(date +%s)"
curl -fsS -X POST 'https://124.222.193.241:6259/_matrix/push/v1/notify' \
  -H 'Content-Type: application/json' \
  --data '{"notification":{"devices":[{"pushkey":"https://124.222.193.241:6259/'"$TOPIC"'"}]}}'
curl -fsS "https://124.222.193.241:6259/$TOPIC/json?poll=1"
```

第一条应返回 `{"rejected":[]}`，第二条应显示一条正文为 Matrix JSON 的消息。

## 二、构建并安装新的 iOS 包

项目中已把 `PUSH_NOTIFICATIONS_GATEWAY_URL` 的默认值改为上述 ntfy Matrix 网关，
并让 FluffyChat 注册完整主题 URL 作为推送键。
**必须用改过的代码重新构建并安装 iOS IPA**，旧 IPA 仍注册 Cloudflare 网关和
`ntfy:<主题>`，只改 1Panel 环境变量不会更新它。

若使用 GitHub Actions 的 **Build Mobile Packages**，先把修改后的代码提交到
构建来源，并确认手动运行输入框 `push_notifications_gateway_url` 为：

```text
https://124.222.193.241:6259/_matrix/push/v1/notify
```

更新安装时不要卸载旧 App 或清除应用数据，避免原主题改变。
打开 FluffyChat 并进入聊天列表，使其重新注册 Matrix Pusher；然后在
“设置 → 通知 → 设备”中确认网关地址是上面的 IP 地址。

## 三、验收

让 FluffyChat 退到后台并锁屏，从另一个 Matrix 账号发送一条新消息。
ntfy App 应收到包含 Matrix JSON 的通知。若未收到，检查 Matrix homeserver
是否能通过公网 HTTPS 访问 `124.222.193.241:6259`，以及新的推送器是否出现。
