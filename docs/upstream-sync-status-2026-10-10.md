<!-- SPDX-FileCopyrightText: 2026 Contributors to FluffyChat -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# 上游同步进度

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

保留照片发送、云贴纸、语音转录、Office、Android 常驻同步、iOS ntfy/SideStore、无 App Group 回退和 Cloudflare 部署。Matrix 仍固定 hosted 14.0.0。

## 验证

已核对 Matrix 14、LiveKit 2.12.0、CallKit 3.1.5、UnifiedPush Android 3.4.1 的相关源码接口。本地 Dart 格式、差异、ARB JSON 与 Android manifest XML 检查通过。本机没有 Flutter；新增测试尚未执行，静态分析与平台编译须在 GitHub Actions 验证。

当前改动尚未提交或上传，远端 main 仍为上述比较基线，未启动新构建。自动审批服务在提交命令上连续超时，命令未执行；这次是审批服务失败，不是新的风险拒绝。已请求继续提交、上传和启动构建的确认。

构建通过不能替代真机验证：需要检查旧消息解密、多设备验证、锁屏接听、音频路由、返回键退出后推送和冷启动。初始化加密身份本身会重建秘密存储、备份与交叉签名，新增流程会在已连接时先下载备份。

## 后续配套迁移

原生图片、分享和文件选择依赖与 Apple Swift Package 工程迁移尚未实施。已核对升级说明：native_imaging 1.0.0 新增 Swift Package 并要求 iOS 15；receive_sharing_intent 1.9.0 移除 CocoaPods，要求 Scene 生命周期和 Share Extension 的 Swift Package 产品链接；file_picker 13 移除旧参数并将文件长度改为可空值。当前 Flutter 版本与 Scene 配置满足部分前提，但仍需配套原生工程、分享扩展和 lock 更新及构建验证。

桌面安装器、商店发布和完整翻译合并按实际分发渠道处理，不直接替换本仓库发布目标。

本次分批移植，不是完整合并 174 个上游提交。原始差异见 `upstream-feature-comparison-2026-10-10.md`。
