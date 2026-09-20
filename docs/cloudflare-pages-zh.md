<!--
SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Cloudflare Pages 部署

此项目可以部署到 Cloudflare Pages。推荐由 GitHub Actions 构建后上传，原因是
Web 版本在普通的 `flutter build web` 之前还需要 Rust、Vodozemac WASM、
`native_imaging` 和 LiveKit E2EE Worker 等准备步骤。

## 首次配置

1. 在 Cloudflare Pages 创建名为 `fluffychat` 的项目。
2. 创建一个允许编辑该 Pages 项目的 Cloudflare API Token。
3. 在 GitHub 仓库的 Actions secrets 中配置：
   - `CLOUDFLARE_API_TOKEN`
   - `CLOUDFLARE_ACCOUNT_ID`
4. 把 AIHubMix 密钥保存为 Cloudflare Pages secret，变量名必须为
   `AIHUBMIX_API_KEY`。不要把密钥写入 `config.json`、Dart 源码或 GitHub
   仓库。

可以在本地登录 Wrangler 后执行：

```sh
npx wrangler pages secret put AIHUBMIX_API_KEY --project-name fluffychat
```

## 部署

推送到 `main` 分支，或在 GitHub Actions 手动运行
`Deploy Web to Cloudflare Pages`。工作流会依次准备 Web 原生模块、构建
Flutter Web、复制运行时配置并部署静态资源与 `/api/transcribe` Pages
Function。

手机端若要复用同一转录代理，构建时传入完整地址：

```sh
flutter build apk --release \
  --dart-define=VOICE_TRANSCRIPTION_ENDPOINT=https://你的域名/api/transcribe
```

Web 端默认使用同源 `/api/transcribe`，无需在前端配置 API 密钥。
