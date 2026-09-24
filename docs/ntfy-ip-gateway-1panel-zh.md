# 无域名 IP 部署方案

现有 ntfy 容器继续使用，不需要重新构建。额外运行的只是一个很小的 Matrix 转换器，
用于生成通知标题、消息内容和 FluffyChat 房间点击链接。

## 地址不要混淆

```text
现有 ntfy 公网地址：      https://124.222.193.241:6259
现有 ntfy 内网地址：      http://192.168.1.6:40265
转换器本机端口：          127.0.0.1:41065
Matrix 推送网关公网地址： https://124.222.193.241:6259/_matrix/push/v1/notify
```

## 1. 保持现有 ntfy

现有 ntfy 容器保持：

```text
NTFY_BASE_URL=https://124.222.193.241:6259
NTFY_UPSTREAM_BASE_URL=https://ntfy.sh
主机 192.168.1.6:40265 → 容器 80
```

## 2. 构建转换器

在仓库根目录执行：

```bash
docker build -f server/push-gateway/Dockerfile -t fluffychat-push-gateway:1.0 .
docker compose -f server/push-gateway/compose.yaml up -d
```

测试：

```bash
curl http://127.0.0.1:41065/healthz
```

应返回包含 `"healthy":true` 的 JSON。

## 3. 修改 6259 的反向代理

保留原来的 `/` 到 ntfy 的代理，只新增：

```nginx
location = /_matrix/push/v1/notify {
    proxy_pass http://127.0.0.1:41065;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

不要把整个 `/` 改到 `41065`，否则 ntfy App 会无法访问。

## 4. 构建 iOS 包

使用：

```text
PUSH_NOTIFICATIONS_GATEWAY_URL=https://124.222.193.241:6259/_matrix/push/v1/notify
```

安装新 IPA 后，进入聊天列表，再到“设置 → 通知 → 设备”确认推送器出现。
ntfy App 继续使用现有服务器和主题。

## 5. 验收

让 FluffyChat 进入后台并锁屏，从另一个 Matrix 设备发消息。
通知应显示类似：

```text
房间名称
发送者 · 2 条未读消息
```

点击通知应通过 `im.fluffychat://room/...` 打开对应房间。
