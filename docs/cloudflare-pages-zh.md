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
   仓库。转录模型默认使用服务商文档支持的 `whisper-1`；如需更换，可添加普通
   环境变量 `AIHUBMIX_TRANSCRIPTION_MODEL`，例如 `gpt-4o-mini-transcribe`，
   但所用密钥必须拥有对应模型权限。

## 部署

保存设置后点击“保存并部署”。Cloudflare 会拉取 `main`，准备 Web 原生模块、
构建 Flutter Web，并同时部署静态资源与 `/api/transcribe` Pages Function。
以后推送到 `main` 会自动重新部署，不需要配置 GitHub Actions Secret 或
Cloudflare API Token。

手机端若要复用同一转录代理，构建时传入完整地址：

```sh
flutter build apk --release \
  --dart-define=VOICE_TRANSCRIPTION_ENDPOINT=https://你的域名/api/transcribe
```

Web 端默认使用同源 `/api/transcribe`，无需在前端配置 API 密钥。
