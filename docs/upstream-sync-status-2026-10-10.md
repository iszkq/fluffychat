<!-- SPDX-FileCopyrightText: 2026 Contributors to FluffyChat -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# 上游同步进度

> 历史记录：2026-10-21 已移除旧 iOS 第三方通知集成；本轮结果见 `optimization-status-2026-10-21.md`。

比较基线：我的仓库 `fa88a20e703ca28f68aebece7de2980e3dff7104`，上游 `f94804398acf2c24b50f1b3f4cf9b47d783044d8`。

## 已移植

- 已读状态整组修复，失败后释放并记录异常。
- 历史消息定位限制重复加载，主时间线线程回复定位到根，并检查页面生命周期。
- 已撤回加密消息展示、Android 地图图钉、回复箭头、HTML 方向感知排版、LiveKit 认证诊断。
- 加密恢复先下载已有密钥备份，再重建身份并标记本地密钥重新上传；恢复采用 SDK 默认自签名。
- iOS CallKit/LiveKit 音频会话协调，仅在 iOS 启用。
- Android 使用 application context，保留主引擎，自定义非导出 UnifiedPush 服务复用或启动主引擎。
- Android 汇总通知排除自己，子通知非空时保留，并静默更新；保留账号分组。
- 备份集成测试增加密码确认；新增已读并发/失败重试和汇总通知回归测试。

保留照片发送、云贴纸、语音转录、Office、Android 常驻同步、iOS SideStore、无 App Group 回退和 Cloudflare 部署。Matrix 仍固定 hosted 14.0.0。

## 验证

已核对 Matrix 14、LiveKit/CallKit、UnifiedPush Android 3.4.1 的相关源码接口。本地 Dart 格式、差异、ARB JSON 与 Android manifest XML 检查通过。已安装任务专用 Flutter 3.47.4，配套升级依赖解析成功，整个 lib 静态分析无错误。本地 Windows 测试被缺少 CMake 的原生依赖构建拦截，测试和平台编译交给 GitHub Actions 验证。

前三批已上传：`3ed9fe95b`。该提交的 iOS 与 Web 构建成功。Android 新增已读测试初始化 Client 时缺少数据库，已修正；后续数据库初始化在 widget 假时钟中停住，现改用仅模拟发送接口的 Client，以便独立验证并发与失败重试。最终构建会执行照片、已读、汇总通知、云贴纸、常驻模式回归检查。

构建通过不能替代真机验证：需要检查旧消息解密、多设备验证、锁屏接听、音频路由、返回键退出后推送和冷启动。初始化加密身份本身会重建秘密存储、备份与交叉签名，新增流程会在已连接时先下载备份。

## 后续配套迁移

已配套升级 native_imaging 1.0.0、receive_sharing_intent 1.9.0、file_picker 13.1.0，以及上游 UI、视频、设备信息、CallKit、安全存储等版本约束。保留固定 Matrix 14 和本仓库 Opus/WebView 依赖，并用 Flutter pub get 生成 lock。

iOS 采用上游 Swift Package 工程与动态 SQLCipher 通知数据库封装，移除 CocoaPods；补通知房间名称/头像元数据；保留 Scene 配置、无 App Group 回退和 SideStore 打包。分享扩展采用新插件提供的自动跳转，去掉旧的延时发送补丁。iOS/Android 构建均生成递增 build number。

macOS/Windows 桌面工程、安装器、商店发布和完整翻译合并不在本轮移动端安装包范围内；不替换本仓库发布目标。

本次分批移植，不是完整合并 174 个上游提交。原始差异见 `upstream-feature-comparison-2026-10-10.md`。
