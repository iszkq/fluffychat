<!--
SPDX-FileCopyrightText: 2019-Present Christian Kußowski
SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat

SPDX-License-Identifier: AGPL-3.0-or-later
-->

# FluffyChat 二次开发版

本项目基于开源 Matrix 客户端 [FluffyChat](https://fluffy.chat) 继续开发，使用
[Flutter](https://flutter.dev) 构建。它使用同一套业务代码支持 Android、iOS、
Web、Windows、macOS 和 Linux。

## 本仓库新增和改进

- 支持同时选择多个私聊或群聊转发消息。
- 保持非 iOS 平台优先发送 OGG/Opus 语音，兼容 Element X。
- 接收端根据文件真实内容识别 OGG、AAC、M4A、MP3、WAV、FLAC、WebM、
  AMR 和 3GP，降低 MIME 或扩展名错误造成的播放失败。
- 语音消息支持 AI 转文字、复制转录内容、展开和收起。
- 内置可搜索、可切换分类的云端贴纸库，发送时自动转存到 Matrix 媒体库。
- 提供 Cloudflare Pages Function 代理，API 密钥不会进入网页包或手机安装包。
- 优化 Web 音频与图片缓存，降低媒体消息较多时的浏览器内存占用。
- 支持 Cloudflare Pages 连接 GitHub 后自动构建和部署。

## 原项目能力

- 文字、图片、语音、视频和文件消息
- Matrix RTC 音视频通话
- 私聊、群聊、公共频道和空间
- 推送通知与位置共享
- Material You 界面
- 自定义表情和贴纸
- 端到端加密、聊天备份、Emoji 验证与交叉签名

## 开发环境

需要安装：

- Flutter，版本以 `.tool_versions.yaml` 为准
- Rust
- Git

克隆并安装依赖：

```sh
git clone https://github.com/iszkq/fluffychat.git
cd fluffychat
flutter pub get
```

运行开发版本：

```sh
flutter run
```

检查代码：

```sh
flutter analyze
flutter test
```

## 配置

Web 端会读取站点根目录下的 `config.json`，完整示例见
`config.sample.json`。只需要保留实际要覆盖的字段。

语音转文字默认请求同源 `/api/transcribe`。AIHubMix 密钥必须作为服务端
`AIHUBMIX_API_KEY` Secret 保存，禁止写入 Dart 源码、`config.json` 或 Git
提交。

Office 在线预览/编辑支持 DOC、DOCX、XLS、XLSX、PPT、PPTX 和 PDF。聊天中的
Office 文件点击后会在内嵌编辑器中打开，可下载编辑后的副本，或将新版本重新
发送到当前聊天。编辑器地址通过 `officeEditorUrl` 配置；必须使用浏览器和手机
都信任的 HTTPS 证书，并允许被 iframe/WebView 嵌入。

Web 端支持直接录制语音。Chrome/Firefox 会发送浏览器实际生成的 WebM/Opus，
Android/macOS 仍保持 OGG/Opus，避免把 WebM 错标成 OGG 后导致其他客户端无法
播放。首次使用时需要允许站点访问麦克风。

## Android

```sh
flutter build apk --release
```

也可以在 GitHub 仓库的 Actions 页面手动运行 `Build Mobile Packages`，输入
完整的 Cloudflare 转录接口地址和 Office 编辑器地址后下载测试 APK。该 APK
使用调试签名，仅用于直接安装和功能测试；上架应用商店前必须配置自己的长期
签名证书。

手机端需要使用已部署的转录代理时，传入完整地址：

```sh
flutter build apk --release \
  --dart-define=VOICE_TRANSCRIPTION_ENDPOINT=https://你的域名/api/transcribe \
  --dart-define=OFFICE_EDITOR_URL=https://你的Office域名
```

## iOS / iPadOS

需要 macOS、Xcode 和有效的 Apple 开发者签名：

```sh
./scripts/build-ios.sh
```

`Build Mobile Packages` 也会生成未签名 IPA，供后续签名使用。未签名 IPA 无法
直接安装到普通 iPhone，也不能提交 App Store。

## Web

正式构建前必须生成 Vodozemac WASM、`native_imaging` 和 LiveKit E2EE
Worker，不能省略第一条命令：

```sh
./scripts/prepare-web.sh
flutter build web --release \
  --dart-define=FLUTTER_WEB_CANVASKIT_URL=canvaskit/
```

构建产物位于 `build/web`。Cloudflare 完整上线流程见
[Cloudflare Pages 部署说明](docs/cloudflare-pages-zh.md)。

## 桌面端

```sh
flutter build windows --release
flutter build macos --release
flutter build linux --release
```

Linux 构建前需要安装系统依赖：

```sh
sudo apt install libjsoncpp1 libsecret-1-dev libsecret-1-0 \
  librhash0 libwebkit2gtk-4.0-dev lld
```

## 音频兼容说明

- Android/macOS 在编码器支持时发送 OGG/Opus。
- iOS 因录音库的 Opus 兼容问题，保留 AAC-LC/M4A 回退。
- Web 录音目前仍由原项目禁用。
- 接收端会修正错误的 MIME 和扩展名，但最终解码能力仍取决于操作系统或浏览器。
- AIHubMix 文档没有明确列出 OGG；当前代理会原样上传。如果供应商拒绝 OGG，
  需要在支持 FFmpeg 的后端增加转码，不能在普通 Cloudflare Pages 静态环境完成。

## 文档

- [Cloudflare Pages 部署说明](docs/cloudflare-pages-zh.md)
- [隐私说明](PRIVACY.md)
- [安全说明](SECURITY.md)
- `CHANGELOG.md` 为 FluffyChat 上游历史记录，保留原文以便追溯。

## 致谢与许可

感谢 FluffyChat、Matrix Foundation 及所有上游贡献者。本项目继续遵循
`AGPL-3.0-or-later` 许可证，修改后对外提供网络服务时请同时遵守 AGPL 的源码
公开要求。
