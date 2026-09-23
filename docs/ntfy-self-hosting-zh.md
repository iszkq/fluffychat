<!--
SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# FluffyChat 自建 ntfy 迁移方案

本文用于把当前 iOS 侧载版的通知中转，从公共 `https://ntfy.sh` 迁移到自己的
ntfy 服务。适合交给 AI 或服务器管理员继续执行。

## 一、当前方案状态

当前链路是：

```text
Matrix Homeserver
    ↓
https://flchat.221819.best/_matrix/push/v1/notify
    ↓
ntfy
    ↓
iOS ntfy App
    ↓ 点击通知
im.fluffychat://room/...
```

FluffyChat 已经实现：

- 每个 iOS 客户端生成独立的随机 ntfy 主题；
- 主题保存在本机，并显示在“个人设置 → ntfy 通知主题”；
- Matrix Push Gateway 支持 `ntfy:<topic>`；
- ntfy 通知包含 FluffyChat 房间深链接；
- 点击通知后可以打开对应的 FluffyChat 房间。

## 二、为什么公共 ntfy 会暂时收不到

公共 `ntfy.sh` 会按照访问者 IP、主题和请求频率进行限流。Cloudflare Pages
Function 的请求来自共享的 Cloudflare 出口 IP，连续测试时容易返回：

```text
HTTP 429 Too Many Requests
```

这不是 Matrix 账号、iOS App 或 ntfy 订阅失效。遇到 429 时：

1. 停止连续测试，不要重复发送几十次测试消息；
2. 等待限流窗口恢复；
3. 再发送一条真实 Matrix 消息；
4. 正式多人使用时迁移到自建 ntfy。

当前代码已经使用 ntfy 的 JSON 发布格式，并支持标准 HTTP 发布兜底。不要为了
反复测试而快速发送大量请求，否则会再次触发公共服务限流。

## 三、正式推荐方案

正式项目建议使用：

```text
自己的 VPS
  └── ntfy.example.com
```

推荐使用 Docker 部署 ntfy，并使用 Caddy、Nginx 或 Traefik 提供 HTTPS。

不建议把 ntfy 部署成 Cloudflare Pages Function。ntfy 是需要持续运行、保存消息
缓存和处理订阅连接的服务，应放在 VPS 或其他长期运行的服务器上。

## 四、Docker Compose 示例

在服务器上创建 `/opt/ntfy/docker-compose.yml`：

```yaml
services:
  ntfy:
    image: binwiederhier/ntfy:latest
    restart: unless-stopped
    command: serve
    environment:
      NTFY_BASE_URL: https://ntfy.example.com
      NTFY_CACHE_FILE: /var/lib/ntfy/cache.db
      NTFY_AUTH_FILE: /var/lib/ntfy/auth.db
      NTFY_AUTH_DEFAULT_ACCESS: deny-all
      NTFY_ENABLE_LOGIN: "true"
      NTFY_BEHIND_PROXY: "true"
      # iOS 自建服务需要把轮询注册请求转发到上游，才能使用系统推送。
      NTFY_UPSTREAM_BASE_URL: https://ntfy.sh
    volumes:
      - ./data:/var/lib/ntfy
    ports:
      - "127.0.0.1:8093:80"
```

启动：

```bash
cd /opt/ntfy
docker compose up -d
docker compose logs -f ntfy
```

`NTFY_UPSTREAM_BASE_URL=https://ntfy.sh` 不代表消息继续发布到公共 ntfy；它用于
自建 ntfy 为 iOS 客户端注册系统推送。消息内容仍然保存在并发布到自己的 ntfy
服务器。

## 五、HTTPS 反向代理

以 Caddy 为例：

```text
ntfy.example.com {
    reverse_proxy 127.0.0.1:8093
}
```

先把 DNS 的 `ntfy.example.com` A 记录指向 VPS，再启动 Caddy。确认以下地址可以
打开 ntfy 页面：

```text
https://ntfy.example.com
```

必须使用有效 HTTPS，不要让手机连接 HTTP 地址。

## 六、修改 FluffyChat 网关配置

在 Cloudflare Pages 项目的环境变量中设置：

```text
NTFY_BASE_URL=https://ntfy.example.com
```

然后重新部署 Cloudflare Pages。Matrix Push Gateway 地址保持不变：

```text
https://flchat.221819.best/_matrix/push/v1/notify
```

这个修改只影响服务器端，一般不需要重新构建 iOS IPA。

## 七、手机端迁移

每个用户需要在 ntfy iOS App 中添加自己的服务器：

```text
https://ntfy.example.com
```

然后订阅 FluffyChat 个人设置中显示的完整主题。

注意：同一个主题名在 `ntfy.sh` 和 `ntfy.example.com` 不是同一个主题。迁移后
必须在自建服务器中重新订阅；FluffyChat 本地保存的主题名称可以继续使用，不必
重新构建 App。

## 八、正式项目的安全要求

- 每个安装实例使用独立、高随机性的主题；
- 不要把主题写入公开仓库、日志或截图；
- 生产环境启用 ntfy 用户和访问控制；
- Cloudflare Function 发布消息时使用专用 ntfy access token；
- 不要把 ntfy 管理员密码写进 GitHub Actions 日志；
- 只给推送网关授予发布权限，不要给它管理员权限；
- 主题泄露后应生成新主题并重新注册 Matrix Pusher。

当前仓库还没有把 `NTFY_ACCESS_TOKEN` 接入网关。正式启用“默认拒绝访问”的
ntfy 前，需要让 AI 完成以下改动：

1. 从 Cloudflare Secret 读取 `NTFY_ACCESS_TOKEN`；
2. 向 ntfy 请求增加 `Authorization: Bearer <token>`；
3. 不把 token 写入客户端、IPA、日志或响应内容；
4. 为没有 token 的开发环境保留当前公共 ntfy 兼容行为。

## 九、验收清单

### 服务器

- [ ] `https://ntfy.example.com` 可以打开；
- [ ] Docker 容器持续运行；
- [ ] HTTPS 证书有效；
- [ ] `NTFY_UPSTREAM_BASE_URL` 已配置；
- [ ] Cloudflare Pages 的 `NTFY_BASE_URL` 已更新；
- [ ] Cloudflare Function 部署成功。

### 手机

- [ ] ntfy App 已添加自建服务器；
- [ ] FluffyChat 个人设置中复制了完整主题；
- [ ] ntfy 已订阅该主题；
- [ ] iOS 设置中允许 ntfy 通知；
- [ ] FluffyChat 的“通知 → 设备”中存在 Push Gateway；
- [ ] FluffyChat 和 ntfy 仅返回桌面、锁屏后能收到通知；
- [ ] 点击新通知能打开 FluffyChat 对应房间。

## 十、测试方式

不要连续快速测试。每次只发送一条：

1. 让 FluffyChat 保持登录；
2. 关闭 FluffyChat 到后台并锁屏；
3. 从另一台 Matrix 设备发送消息；
4. 等待 ntfy 通知；
5. 点击通知并确认进入正确房间。

如果网关返回 `rejected`，先检查 ntfy 服务日志和 Cloudflare Function 日志，
不要马上循环发送测试请求。
