<!-- SPDX-FileCopyrightText: 2026 Contributors to FluffyChat -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# 在原扫码入口中支持新设备登录

实现位置：本地 `fluffychat-main`，不改变原联系人、房间链接的扫码处理。扫描登录码时走新增 MSC4108 分支；扫描普通 Matrix 链接时仍调用 `UrlLauncher.openMatrixToUrl()`。

## 手机使用方式

1. 在已登录的 FluffyChat 中打开「新的聊天 → 扫描二维码」。
2. 扫描 mxchat 桌面显示的登录码，确认当前账号和登录意图。
3. 如果缺少已解锁的密钥，使用手机本地的恢复密钥或备份口令解锁。优先使用用户先前保存在系统安全存储中的恢复凭据；不会新增保存恢复凭据的行为。
4. 比较手机和桌面的校验码，两边一致时分别确认。
5. 在手机上点击「打开授权页面」，在服务器的认证页面批准新设备。浏览器没有认证会话时，服务器仍可能要求登录；FluffyChat 的 Matrix 访问令牌不会被转换成浏览器登录凭据。
6. 返回 FluffyChat 等待完成。新设备必须出现在这个账号下，之后才会传递交叉签名密钥，以及可用且匹配当前备份的备份密钥。

手机取消或请求超时后，不再传递密钥。如果已经在浏览器批准了设备，取消手机后不会自动撤销服务器上已经建立的登录；可在设备管理中撤销该设备。历史消息解密仍需要对应房间密钥存在于备份或设备中，本功能不会生成丢失的历史密钥。

## 协议与范围

- 实现已登录手机扫描新设备二维码的 MSC4108 v2 mode 3 流程，兼容当前 mxchat 使用的 matrix-js-sdk 45.0.0。
- 支持扫码插件返回的二进制载荷、QR byte-mode 数据码字、ECI 标记，以及 8/16 位字节长度字段。避免将随机公钥当 UTF-8 解码。
- 原 `MATRIX` v2 mode 0/1/2 验证码不被误认为登录码；联系人、房间和消息链接仍走原处理。
- 暂未实现 MSC4388 新格式，以及未登录手机扫描已登录设备显示二维码的反向登录流程。不能把所有 Matrix 二维码都视作此登录协议。
- 认证服务必须支持 OAuth 设备授权（device authorization grant）。服务器和设备使用 HTTPS；不绕过证书验证。
- Rendezvous 不携带手机的访问令牌、不跟随重定向，使用 ETag 做条件读写并限制消息大小及等待时间。
- 安全通道使用 X25519、HKDF-SHA512、方向独立的 ChaCha20-Poly1305 密钥和 nonce，与 vodozemac 实际实现互通。
- 授权链接的 origin 必须匹配当前手机账号服务器公布的 issuer。用户明确核对校验码后才能打开授权。
- 新设备 ID 在授权前必须不存在，授权后必须可从当前账号查询到，防止浏览器选错账号后分享密钥。
- 交叉签名私钥在导出前重新推导公钥并与账号公开密钥核对。备份密钥只在公钥与当前备份匹配时附带。
- Matrix Dart SDK 14.1.0 默认不缓存主签名密钥。新增适配从已保存的安全存储恢复凭据或本地输入中解锁，主签名密钥仅保留在本次登录流程内；结束、取消后释放引用，不额外持久化。

## 修改文件

- `lib/pages/new_private_chat/new_private_chat.dart`：原扫码入口接线。
- `lib/pages/new_private_chat/qr_scanner_modal.dart`：保留普通扫码回调，增加登录码分流和订阅清理。
- `lib/pages/new_private_chat/qr_login_dialog.dart`：账号确认、本地解锁、校验码、授权、等待、成功与错误状态。
- `lib/utils/qr_login/`：载荷解析、安全通道、协议状态机、Matrix SDK 账号与密钥适配。
- `lib/l10n/intl_en.arb`、`intl_zh.arb`：新增提示，其余语言沿用生成器的英文回退。
- `pubspec.yaml`、`pubspec.lock`：新增 cryptography，声明直接使用的 test 开发依赖。其余依赖保持锁定。
- `test/qr_login_test.dart`、`test/qr_login_dialog_test.dart`：协议与界面回归。
- `scripts/qr_login_test_peer.mjs`、`scripts/validate_qr_login.py`：离线互通测试及隔离验证入口。

## 验证

先运行 `flutter pub get`。在有完整 native 工具链的环境中：

```sh
flutter analyze lib
flutter test test/qr_login_test.dart test/qr_login_dialog_test.dart
```

原工程的 webcrypto / SQLCipher hook 会使完整工程的测试也要求本机构建工具。如果缺少这些工具，可运行：

```sh
python scripts/validate_qr_login.py --flutter /path/to/flutter --js-project /path/to/mxchat
```

`--js-project` 指向装有 `matrix-js-sdk` 和 `qrcode` 的 Node 项目。本机验证指向相邻的 mxchat（SDK 45.0.0）。未提供它时，只跳过那一项 JavaScript 互通测试。测试 peer 限制外部网络，令牌、密钥和账号均为人工测试数据。

隔离验证会复制原样生产源码、现有自适应按钮、主题配置和生成的本地化文件，记录 SHA256 到 `.dart_tool/qr_login_validation/source-sha256.json`。不使用生产安全通道或加密算法的替身。Matrix SDK 账号适配和扫码控件接线仍须通过原工程静态检查及实机检查。

本次本机验证：20 项协议／界面测试通过，包含真实 JavaScript SDK + Rust ECIES peer 的握手、校验码、设备授权和密钥消息互通。界面测试验证恢复失败重试、取消、超时、浏览器打开失败、中文 320×568 布局。测试中采用人工账号和浏览器授权响应，没有使用真实账号或访问真实认证服务。

完整工程 `flutter build web --no-pub` 已通过。Android/iOS 摄像头实机扫码、真实服务器授权与备份恢复仍需实机联调。本机缺少 Android SDK，移动端包使用仓库现有 GitHub Actions 构建。`Build Mobile Packages` 已增加前置 QR 登录校验，包含真实 JS SDK peer。修改源码不会更新手机上已经安装的旧客户端，需要重新构建安装。
