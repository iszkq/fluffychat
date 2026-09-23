<!--
SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Cloudflare Pages 部署

此项目通过 GitHub Actions 构建并部署到 Cloudflare Pages。Cloudflare Pages 的
Git 集成构建时间有限，而 Flutter Web 构建还需要生成 Vodozemac WASM、
`native_imaging` 与 LiveKit E2EE Worker，因此不建议让 Pages 直接执行完整构建。

## 首次配置

1. 在 Cloudflare Pages 创建名为 `fluffychat` 的项目。不要启用 Git 集成构建，
   或将其暂停，避免 Cloudflare 再次执行完整 Flutter 构建。
2. 在 Cloudflare API Tokens 中创建一个具有 Pages 部署权限的 Token，并将以下
   两项保存为 GitHub 仓库 Secrets：`CLOUDFLARE_API_TOKEN`、
   `CLOUDFLARE_ACCOUNT_ID`。
3. 推送到 `main` 会自动触发
   `.github/workflows/deploy_cloudflare_pages.yml`。该工作流在 GitHub Actions
   中构建 Web，并使用 Wrangler 将 `build/web` 部署到 `fluffychat` 项目。
4. 把 AIHubMix 密钥保存为 Cloudflare Pages secret，变量名必须为
   `AIHUBMIX_API_KEY`。不要把密钥写入 `config.json`、Dart 源码或 GitHub
   仓库。
5. 为 Android 后台消息配置 Firebase：
   - 在 Firebase 项目中添加包名为 `chat.fluffy.fluffychat` 的 Android 应用，
     下载 `google-services.json`。
   - 在 Firebase/Google Cloud 中创建具有 Firebase Cloud Messaging 发送权限的
     服务账号密钥，把完整服务账号 JSON 保存为 Cloudflare Pages 的加密 Secret
     `FIREBASE_SERVICE_ACCOUNT`。
   - 把 `google-services.json` 的完整内容（或其单行 Base64）保存为 GitHub
     Actions 的 Repository secret `GOOGLE_SERVICES_JSON`。该文件和服务账号私钥
     都不得提交到 Git 仓库。
   - 为了让以后生成的新 APK 可以直接覆盖旧版本，还需创建一个长期保存的 Android
     签名密钥，并把以下四项保存为 GitHub Repository secrets：
     `ANDROID_KEYSTORE_BASE64`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`、
     `ANDROID_STORE_PASSWORD`。密钥文件必须单独备份；丢失后无法继续覆盖升级。
6. 如需更换 Office 服务地址，在站点根目录的 `config.json` 中设置
   `officeEditorUrl`。该地址必须使用有效 HTTPS 证书；Office 服务还需允许
   Cloudflare Pages 域名通过 iframe 嵌入。

## 部署

保存 Secrets 后，推送到 `main` 即会自动构建和部署。Cloudflare Pages 只负责托管
构建后的静态文件与 `/api/transcribe` Pages Function，不再承担 Flutter/Rust 构建。

Android 的 Matrix 推送网关同时部署在：

```text
https://你的域名/_matrix/push/v1/notify
```

此接口由 Matrix homeserver 调用，不要在浏览器中直接测试。没有配置
`FIREBASE_SERVICE_ACCOUNT` 时会返回 503，避免生成一个看似成功但实际无法发送
通知的网关。

没有 Apple Developer 账号时，可以使用同一个网关为 iOS 侧载版转发到 ntfy。
完整配置见 [iOS 侧载版 Matrix 推送](ios-ntfy-push-zh.md)。在 Cloudflare
Pages 中设置 `NTFY_BASE_URL`（默认 `https://ntfy.sh`），然后使用随机主题构建
iOS：

```sh
flutter build ios --release \
  --dart-define=NTFY_TOPIC=你的随机ntfy主题 \
  --dart-define=PUSH_NOTIFICATIONS_GATEWAY_URL=https://你的域名/_matrix/push/v1/notify
```

手机端若要复用同一转录代理，构建时传入完整地址：

```sh
flutter build apk --release \
  --dart-define=VOICE_TRANSCRIPTION_ENDPOINT=https://你的域名/api/transcribe \
  --dart-define=OFFICE_EDITOR_URL=https://你的Office域名 \
  --dart-define=PUSH_NOTIFICATIONS_GATEWAY_URL=https://你的域名/_matrix/push/v1/notify
```

Web 端默认使用同源 `/api/transcribe`，无需在前端配置 API 密钥。

仓库的 `Build Mobile Packages` 工作流会检查 `GOOGLE_SERVICES_JSON`、启用
Firebase Messaging、使用固定 Release 密钥签名，并生成
`fluffychat-android-fcm.apk`。若 Firebase 配置、签名密钥缺失或包名不匹配，
Android 构建会明确失败，不再产出没有后台推送能力或无法覆盖升级的 APK。
第一次从旧的 debug APK 切换到固定 Release 签名时，需要卸载旧包后再安装一次；
从这版开始，只要保留同一份签名密钥，后续 APK 都能直接覆盖升级。
