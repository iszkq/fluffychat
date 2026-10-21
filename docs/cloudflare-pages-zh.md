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
5. Android 使用常驻 Matrix 同步，不需要 Firebase 或独立推送网关。
   移动包工作流仍要求配置固定 Release 签名：`ANDROID_KEYSTORE_BASE64`、
   `ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`、`ANDROID_STORE_PASSWORD`。
   签名密钥需要单独备份，后续覆盖升级依赖同一密钥。
6. 如需更换 Office 服务地址，在站点根目录的 `config.json` 中设置
   `officeEditorUrl`。该地址必须使用有效 HTTPS 证书；Office 服务还需允许
   Cloudflare Pages 域名通过 iframe 嵌入。

## 部署

保存 Secrets 后，推送到 `main` 即会自动构建和部署。Cloudflare Pages 只负责托管
构建后的静态文件与 `/api/transcribe` Pages Function，不再承担 Flutter/Rust 构建。

iOS 侧载版暂未提供额外后台通知方案，后续另行适配。

手机端若要复用同一转录代理，构建时传入完整地址：

```sh
flutter build apk --release \
  --dart-define=VOICE_TRANSCRIPTION_ENDPOINT=https://你的域名/api/transcribe \
  --dart-define=OFFICE_EDITOR_URL=https://你的Office域名
```

Web 端默认使用同源 `/api/transcribe`，无需在前端配置 API 密钥。

仓库的 `Build Mobile Packages` 使用固定 Release 密钥签名，生成
`fluffychat-android-background-sync.apk`。签名缺失会明确失败。
从旧的 debug 签名切换到 Release 签名时需要卸载旧包后安装；保留同一份
Release 密钥后，后续安装包可以直接覆盖升级。
