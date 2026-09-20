<!--
SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Cloudflare Pages 部署

此项目可以通过 Cloudflare Pages 连接 GitHub 仓库自动部署。仓库提供了专用构建
脚本，用于安装 Cloudflare 构建环境缺少的 Flutter、Rust 和 `yq`，并生成
Vodozemac WASM、`native_imaging` 与 LiveKit E2EE Worker。

## 首次配置

1. 在 Cloudflare Pages 选择“连接到 Git”，授权并选择 GitHub 仓库。
2. 生产分支选择 `main`，框架预设选择“无”，根目录保持仓库根目录。
3. 构建命令填写 `bash ./scripts/cloudflare-pages-build.sh`，构建输出目录填写
   `build/web`。
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

保存设置后点击“保存并部署”。Cloudflare 会拉取 `main`，准备 Web 原生模块、
构建 Flutter Web，并同时部署静态资源与 `/api/transcribe` Pages Function。
以后推送到 `main` 会自动重新部署，不需要配置 GitHub Actions Secret 或
Cloudflare API Token。

Android 的 Matrix 推送网关同时部署在：

```text
https://你的域名/_matrix/push/v1/notify
```

此接口由 Matrix homeserver 调用，不要在浏览器中直接测试。没有配置
`FIREBASE_SERVICE_ACCOUNT` 时会返回 503，避免生成一个看似成功但实际无法发送
通知的网关。

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
