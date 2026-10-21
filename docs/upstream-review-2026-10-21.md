<!-- SPDX-FileCopyrightText: 2026 Contributors to FluffyChat -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# 本地核对与上游适配分析（2026-10-21）

> 以下为改动前分析。后续实施按用户要求保持转录调用方式、不新增限额，并移除旧 iOS 通知方案。实施结果见 `optimization-status-2026-10-21.md`。

## 1. 核对结果

本地仓库源码已经是你的 GitHub 仓库最新版，无需覆盖更新。本次只新增本分析文档，没有移植上游代码，也没有提交、推送或触发部署。

| 项目 | 核对结果 |
| --- | --- |
| 你的仓库 | `iszkq/fluffychat`，默认分支 `main` |
| 最新提交 | `c159e70af33dd30002f9ae97c9d4ac4d464ea8b8`，2026-10-13，修复 iOS 播放没有 EOS 的完整 OGG 语音 |
| 本地与该提交比较 | 对全部 694 个 Git 跟踪文件计算 SHA-256，差异 0、缺失 0 |
| 本地额外内容 | `.codex-mobile-upload/` 工作副本和 `.codex-transcription-probe.wav`，均保留 |
| Git 状态 | 当前根目录没有 `.git`；嵌套工作副本 `.codex-mobile-upload` 在相同提交，工作区干净 |
| 上游 | `krille-chan/fluffychat`，默认分支 `main` |
| 上游最新提交 | `6d158792b915a1d9b94e18d68387d5c7254297ca`，2026-10-20，翻译合并 |
| 上游最新稳定版 | `v2.11.1`，2026-10-19 发布 |
| 项目版本字段 | 你的版本 `2.9.5+3566`；上游 main 为 `2.11.1+3572` |
| Flutter | 本地配置 `3.47.4`；上游 `.fvmrc` 为 `3.47.7` |

版本号不等于功能差距：你的分支已经分批移植了不少上游代码，同时保留独立的语音、相机、云贴纸、Office、Android 常驻同步和 iOS ntfy/SideStore 功能。

证据：[你的最新提交](https://github.com/iszkq/fluffychat/commit/c159e70af33dd30002f9ae97c9d4ac4d464ea8b8)、[上游最新提交](https://github.com/krille-chan/fluffychat/commit/6d158792b915a1d9b94e18d68387d5c7254297ca)、[上游稳定版](https://github.com/krille-chan/fluffychat/releases/tag/v2.11.1)。

## 2. 实际差距与合并方式

- 共同祖先：`372628048eb4708c0e722d259b86d833241dbc8f`。
- 按提交身份统计，你的分支独有 65 个提交，上游独有 273 个提交。手工移植不会保留原提交身份，因此这不能解释为缺少 273 项更新。
- 相对现有同步文档记录的上游基线 `f94804398acf2c24b50f1b3f4cf9b47d783044d8`，上游又有 99 个提交，其中 59 个非合并提交；包含依赖、翻译、发布配置和代码更新。部分提交作者日期早于基线，但之后才进入 main。
- 两个最新代码树有 260 个文件差异，其中混合了上游新增和你自己的定制，不能按上游代码树直接覆盖。
- 在临时克隆中运行 `git merge-tree --write-tree --name-only origin/main upstream/main`，完整合并产生 22 个冲突文件，没有改动当前源码或分支。

结论：继续采用分批移植。先处理明确的小修复，再做通话/通知适配，之后单独迁移 SDK 与恢复流程。

## 3. 优先移植的小修复

以下均核对了当前代码和上游补丁，当前分支仍未包含对应修改。

| 优先级 | 内容与当前问题 | 相关文件 / 上游提交 |
| --- | --- | --- |
| 高 | 高级设置重置直接 `SharedPreferences.clear()`，同时清掉多账号索引和 ntfy 等非设置枚举数据。应只删除 `AppSettings` 管理的键，并明确其余功能的重置语义。 | `lib/config/setting_keys.dart`；`88439bad` |
| 高 | 恢复密钥按钮显示“复制”，实际调用默认分享逻辑，移动端会打开分享面板。已有 `FluffyShare.share(copyOnly: true)` 可复用。 | `lib/pages/bootstrap/widgets/store_recovery_key_view.dart`；`c9535e92` |
| 中 | MXID 登录输入框使用邮箱键盘，手机上输入 `@user:server` 的冒号不方便。 | `lib/pages/login/login_view.dart`；`e974f4e7` |
| 中 | 图片加载缺少“账号已登录”和 `mxc:` 协议检查，可在退出登录/无效 URI 时发起不适当的媒体请求。 | `lib/widgets/mxc_image.dart`；`1e3540bf` |
| 中 | 头像占位字母用 UTF-16 `substring(0, 1)`，可能拆开 emoji 或组合字符。 | `lib/widgets/avatar.dart`；`2272cb7c` |

推荐第一批完成这些小修复，验证多账号与 ntfy 数据保留、恢复密钥复制、MXID 输入和 emoji 头像。

## 4. 通话与通知：收益较大，需要结合定制

### MatrixRTC 服务发现与通话状态

当前 `getLiveKitServiceUrls()` 只检查 well-known/fallback，仍留着查询 RTC transports 的 TODO。上游 `68d26b1b` / `806fb205` 增加 `/_matrix/client/unstable/org.matrix.msc4143/rtc/transports` 查询，可以适配采用新服务发现方式的服务器；查询失败时仍需保留现有 well-known 与手动 fallback。

上游 `1a0a407f` 还增加两项当前缺失的修复：

- 校验收到的通话密钥是否属于当前房间与 call ID。
- 同时监听 sync 的 timeline 和 state 中的成员事件，避免成员变更只出现在 state 时不刷新。

这批可以保留已移植的 iOS CallKit 音频会话协调。LiveKit 依赖当前约束为 `^2.12.0`，上游为 `^2.13.1`；升级时应根据 lock 中实际版本验证锁屏接听、扬声器、蓝牙和多人进出通话，不能只靠编译判断。

### Android 通知点击与主引擎复用

上游 `ec6f5a2d` 修复“Flutter 引擎保留、Activity 重新创建后，点击通知没有再次打开房间”：把打开通知房间的逻辑拆成独立方法，并在从 detached 返回时重新处理。

你的代码需要额外适配：`BackgroundPush.setupPush()` 在 Android 开头直接 return，后面的 `getNotificationAppLaunchDetails()` 不会在这条路径执行。虽然运行中已注册点击回调，但启动通知的恢复路径和 Activity 重建路径仍应补齐并测试。

不要为了套用上游而重新启用 Android FCM 注册或覆盖常驻同步模式。重点验证：运行中点击、退到后台点击、返回键退出后点击、冷启动点击、多账号目标房间和去重。

### 邀请接受/拒绝流程

上游 `6b23c107` 在房间中展示明确的接受、拒绝和拒绝并屏蔽操作，替代点开邀请即加入。你的 `chat_view.dart` / `chat_list.dart` 仍保留旧加入逻辑。

此项适合第二批单独移植，需要同时改聊天页、列表、通知跳转和翻译；不能只套用上游通知直接进入邀请房间的改动，否则旧页面可能自动加入。

## 5. Matrix SDK 14.1 与数据库恢复：建议做，但单独成批

你的分支固定 `matrix: 14.0.0`，上游使用 `^14.1.0`。已下载并检查 pub.dev 的 Matrix 14.1.0 源码与 CHANGELOG，确认新增了数据库 `secureStorage` 回调，用于把客户端数据和 SSSS 缓存同时写入安全存储，支持数据库重建后恢复；也包含邀请后等待同步、入站会话比较、消息排序、mentions 和设备查询修复。

你当前已有 `init_with_restore.dart` 会话备份，不是完全没有恢复机制。但它在客户端初始化成功后备份 access token、Olm account、设备信息等，没有 SDK 14.1 的 SSSS 缓存集成；桌面支持范围也不同。新增 SDK 能力应与旧备份协调，不能直接删掉旧逻辑。

建议一起处理：

1. 先升级 SDK 并生成 lock，核对 `storeClient()` 等 API、测试辅助类和通知扩展兼容性。
2. 将安全存储回调接入数据库，并统一数据库密钥、SDK 备份和旧会话备份的存储策略。
3. 保留现有共享 Keychain / 私有 Keychain 回退及迁移，适配无 App Group 的 SideStore 安装。
4. 对打不开数据库的情况先区分权限、Keychain 不可用、迁移失败与真实损坏；保留可恢复的原库副本，再考虑重建。当前和上游都存在失败后删库重试路径，不宜直接扩大使用范围。
5. 验证旧安装升级、强制结束后启动、离线启动、多账号、退出账号后安全存储清理、历史消息解密和密钥备份恢复。

上游 `v2.11.1` 的关键热修是撤销未经迁移的 iOS Keychain `accessibility: first_unlock` 设置（`f99c40a8`）。你的代码目前没有这个设置，故不需要为了该热修单独改代码；需要在后续迁移时避免把它带入。此能力主要帮助恢复会话与缓存，不等于恢复所有未备份的消息解密密钥。

SDK 证据：[Matrix 14.1.0](https://pub.dev/packages/matrix/versions/14.1.0/changelog)、[上游数据库集成](https://github.com/krille-chan/fluffychat/commit/6121f97acee1b118e2352e73ab4c101153b1fb8b)。

## 6. 可以增加的适配

| 建议 | 依据及实施方向 | 建议顺序 |
| --- | --- | --- |
| 完整 `matrix:` 深链 | Android/iOS 已注册 scheme，但当前顶层路由缺少上游新增解析。保留已有 `im.fluffychat://room` 和多账号参数；补房间、别名、用户、事件定位及非法 URI 检查。上游实现含 `debugger()` 且直接索引路径段，应整理后移植。Android 自定义 scheme 目前只声明 host `chat`，与路由和 ntfy 生成的 host `room` 也需统一。 | 高 |
| iOS 从输入菜单粘贴图片 | 上游 `b9c0c0aa` 提供剪贴板图片入口；接入你已有照片预览与发送流程，复用 HEIC/方向归一化。 | 中 |
| 语音编码兼容回退 | 当前原生录音强制 Opus，不支持时直接报错。保留已有 CAF/WebM/OGG 转换及无 EOS 修复，并按设备能力设计 AAC 回退、格式标注和发送策略。上游改为 Apple 平台 AAC，与你保持 OGG/Element X 互通的目标不同，不适合直接替换。 | 中 |
| 转录服务访问与额度控制 | 当前 `functions/api/transcribe.js` 有 25 MB 限制，但源码中没有调用者鉴权、用户额度、并发限制或上游超时；可增加短期凭证、按用户限额、超时/取消和用量统计。是否已由 Cloudflare 外层限制，本次未检查线上配置。 | 中 |
| 转录与 Office 的数据提示 | 转录上传解密后的音频，Office 将文件内容交给配置的编辑服务；可在首次使用时说明处理服务，并提供管理员开关。Office 已有分块传输与确认机制，可以补大文件限制、取消及失败重试。 | 中 |
| Android 后台可靠性诊断 | 已有常驻/仅运行时模式，可增加厂商自启动、电池限制入口，以及最近同步/服务状态诊断，帮助排查国产 ROM 锁屏收不到消息。 | 中 |
| Windows/macOS/Linux 适配 | 按实际发布需求补桌面构建和 macOS 角标。Office 的 IO 分支统一调用 `webview_flutter`，需要逐个平台确认插件支持，给未支持的平台外部浏览器或下载回退。 | 后续 |
| 翻译与文档 | 合并上游简体中文时保留自定义 key。README 对 Web 录音和 APK 调试签名的描述已与当前录音实现、CI 强制正式签名不一致；旧同步文档引用的比较报告也不存在。 | 配套 |

## 7. 工程与验证建议

上游 Flutter 3.47.7 和 FVM 可作为后续工具链统一目标。若切换 FVM，应同步修改仍读取 `.tool_versions.yaml` 的 Actions、Cloudflare 脚本与其他构建入口；只改工具版本文件会使 CI 断开。上游 UI 依赖已到 `material_ui: 1.7.0`、`cupertino_ui: ^1.1.3`，应与截图/真机验证一起升级。

已有 CI 证据：你的最新提交的 [移动端构建](https://github.com/iszkq/fluffychat/actions/runs/38349542041) 中 Android 和 iOS 两个 job 都成功，[Web 部署工作流](https://github.com/iszkq/fluffychat/actions/runs/38349482725) 也成功。构建通过不代表锁屏通知、蓝牙、旧账号升级等场景已验证。

可以补的 CI：Web 专用语音编码测试、`server/push-gateway/server.test.mjs`、通知冷启动/多账号路由回归、SDK 安全存储迁移与登出清理、关键页面截图。完整 PR 工作流已有 `flutter test`；但手动移动包工作流只跑选定用例，不能据移动包成功推断所有测试都通过。

本次未运行新的 Flutter 编译或测试：当前 shell 未找到 Flutter/Dart 命令，且此次没有修改可执行源码。结论来自源码比较、Git 历史、SDK 源码、临时合并预演与现有 CI 状态，不把静态分析推断当作真机复现结果。

## 8. 建议实施批次

1. **稳定性小修**：设置重置、恢复密钥复制、MXID 键盘、头像字符、媒体 URI 检查；补通知启动路径与深链校验。
2. **通信互通**：RTC transports、通话密钥过滤、state 成员刷新；邀请流程和 iOS 粘贴图片分别移植。
3. **SDK/恢复迁移**：Matrix 14.1、安全存储整合、旧安装迁移与恢复测试。
4. **工具链与扩展**：Flutter/依赖、CI、翻译、转录额度控制及按需桌面支持。

每批保留照片发送、原生 iOS 相机、语音转换、云贴纸、Office、Android 常驻同步、iOS ntfy/SideStore 和 Cloudflare 发布配置。

## 附：完整合并的 22 个冲突文件

```text
.github/workflows/main_deploy.yaml
CONTRIBUTING.md
README.md
android/app/src/main/AndroidManifest.xml
android/app/src/main/kotlin/chat/fluffy/fluffychat/MainActivity.kt
android/app/src/main/kotlin/chat/fluffy/fluffychat/UnifiedPushService.kt
ios/FluffyChat Share/ShareViewController.swift
ios/Notification Service Extension/NotificationService.swift
ios/Notification Service Extension/SqlCipherDatabase.swift
ios/Runner.xcodeproj/project.pbxproj
ios/Runner.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
ios/Runner.xcworkspace/xcshareddata/swiftpm/Package.resolved
lib/l10n/intl_zh.arb
lib/pages/chat/chat.dart
lib/pages/chat/recording_view_model.dart
lib/pages/chat_list/chat_list.dart
lib/utils/matrix_sdk_extensions/flutter_matrix_dart_sdk_database/cipher.dart
lib/utils/url_launcher.dart
lib/widgets/matrix.dart
pubspec.lock
pubspec.yaml
scripts/release-ios-testflight.sh
```
