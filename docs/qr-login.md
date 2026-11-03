<!-- SPDX-FileCopyrightText: 2026 Contributors to FluffyChat -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# 在原扫码入口中支持新设备登录

实现位置：本地 `fluffychat-main`，不改变原联系人、房间链接的扫码处理。新版 mxchat 默认生成应用自定义的密码登录码；扫描普通 Matrix 链接时仍调用 `UrlLauncher.openMatrixToUrl()`。旧版标准 MSC4108 登录码继续走原授权流程。

## 新版 mxchat：服务器保存凭据，一次确认登录

支持密码登录的服务器从 3.0.3 起优先打开 App 内账号密码登录页，避免 OIDC/SSO 网页授权绕过密码采集。仅支持网页登录的服务器保留原流程，但网页授权本身不能建立密码记录。

1. 安装新版手机端后，使用账号密码成功登录一次，并完成原有的加密设置或恢复。客户端在加密可用后，将密码加密上传到本账号的私有 `org.mxchat.login_credentials.v1` account data。账号身份由 Matrix 用户 ID 确定，不放入公开 profile，不需要修改服务器配置。
2. 电脑展示登录码；手机扫描，确认账号和登录意图。此分支没有校验码、OAuth 授权码或浏览器授权。
3. 手机从服务器直接读取最新记录，用已有的交叉签名私钥解密，再通过二维码绑定的临时加密通道发送账号密码。电脑使用普通 `m.login.password` 创建独立的 `MXCHAT_…` 设备，验证返回身份后通知手机。
4. 手机 3.0.5 与电脑 0.3.12 通过 `org.mxchat.cached_secrets: 1` 协商自动授权：手机发送已缓存且公私钥匹配的 self/user signing seed、当前 master 公钥指纹及可用的匹配备份密钥。电脑先核对服务器身份，再导入签名密钥、信任扫码确认的身份、签署自身设备，自动恢复备份；不需要 master 私钥或第二次手动 SAS 验证。缺少可用密钥则明确报错，不自动弹出第二次验证。旧版电脑保留完整 bundle / 手动验证兼容分支。

凭据记录没有客户端设置的到期时间，服务器保留到被覆盖、清除或账号删除；这不意味着服务器保证永久保留。在本应用内成功修改密码后会替换记录；在其他客户端或服务器改密后，需要在新版手机端重新使用当前密码登录。此前已有的令牌不能反推出密码，旧登录和纯 SSO 登录不会自动产生密码记录。

记录使用随机 nonce 的 AES-256-GCM 加密，HKDF-SHA256 从已有且与公开自签名密钥匹配的 self-signing seed 派生独立用途的加密密钥，并绑定 Matrix 用户 ID（已包含身份服务器）与密钥 ID。服务器只收到密文；仅有访问令牌而没有相应私钥不能读取密码。持有相应交叉签名私钥的账号设备可以解开记录，这是该便利登录功能的权限范围。

明文密码不写本地数据库、系统密码存储、会话文件或日志。密码登录后，仅在内存等待密钥可用和上传重试，最多十分钟，成功上传、退出账号后清除引用；Dart/JavaScript 的不可变字符串不能保证立即从运行时内存擦除。Matrix 会将 account data 同步到设备并缓存，所以本地仍可能存在密码**密文**，以及应用原本必须保存的登录令牌和加密状态。私钥被重置后，旧记录不可解密，需要重新密码登录建立记录。

应用扩展在 `MATRIX` v2 的 mode **4** 中明确区分，不伪装成标准 MSC4108 mode 3；老客户端拒绝该格式。复用 MSC4108 的加密 rendezvous 通道和 ETag 传输，但不执行 OAuth 授权。省略校验码比较意味着用户必须在自己正在操作的电脑上扫码确认；二维码不包含密码。客户端不新增永久的扫码通道。

电脑只保存登录令牌和自身加密状态，不保存收到的账号密码。认证成功但密钥交接失败、取消或身份不匹配时，电脑尝试撤销本次新登录；网络故障下撤销可能失败，仍可通过设备管理撤销。历史解密受手机和备份中实际存在的房间密钥限制。

## 旧标准 MSC4108 登录码的手机使用方式

1. 在已登录的 FluffyChat 中打开「新的聊天 → 扫描二维码」。
2. 扫描 mxchat 桌面显示的登录码，确认当前账号和登录意图。
3. 手机优先使用已有缓存及用户先前保存在系统安全存储中的恢复凭据。新版 mxchat 明确声明支持设备验证交接时，缺少完整主签名私钥不再强制输入恢复密钥；其他客户端仍保留完整密钥解锁路径。
4. 比较手机和桌面的校验码，两边一致时分别确认。
5. 在手机上点击「打开授权页面」，在服务器的认证页面批准新设备。浏览器没有认证会话时，服务器仍可能要求登录；FluffyChat 的 Matrix 访问令牌不会被转换成浏览器登录凭据。
6. 返回 FluffyChat 等待完成。新设备必须出现在这个账号下。手机持有完整密钥时直接传递交叉签名私钥与可用的匹配备份密钥；否则关闭扫码窗口，在电脑和手机两边接受设备验证，逐项核对表情或数字并分别确认一致。
7. SAS 验证完成后，由 Matrix SDK 向经过验证的同账号设备请求并通过 Olm 加密共享可用密钥。电脑区分“设备已验证”和“历史已恢复”；缺失或从未备份的历史密钥不会凭空恢复。任意一边取消或不一致均不算通过。

手机取消或请求超时后，不再传递密钥。如果已经在浏览器批准了设备，取消手机后不会自动撤销服务器上已经建立的登录；可在设备管理中撤销该设备。历史消息解密仍需要对应房间密钥存在于备份或设备中，本功能不会生成丢失的历史密钥。

## 协议与范围

- 实现已登录手机扫描新设备二维码的 MSC4108 v2 mode 3 流程，兼容当前 mxchat 使用的 matrix-js-sdk 45.0.0。
- 完整 secrets bundle 仍遵循 MSC4108。`m.login.protocol` 中的 `org.mxchat.device_verification: 1` 以及对应交接消息是 mxchat/FluffyChat 的应用扩展，不是 MSC4108 标准，也不代表已经共享密钥。仅在电脑明确声明支持时使用；其他客户端继续使用恢复凭据及完整 bundle。后续 SAS 与 Olm secret sharing 使用标准 Matrix 协议。
- 支持扫码插件返回的二进制载荷、QR byte-mode 数据码字、ECI 标记，以及 8/16 位字节长度字段。避免将随机公钥当 UTF-8 解码。
- 原 `MATRIX` v2 mode 0/1/2 验证码不被误认为登录码；联系人、房间和消息链接仍走原处理。
- 暂未实现 MSC4388 新格式，以及未登录手机扫描已登录设备显示二维码的反向登录流程。不能把所有 Matrix 二维码都视作此登录协议。
- 旧标准模式要求认证服务支持 OAuth 设备授权（device authorization grant）；新版密码模式只要求既有 rendezvous 与密码登录接口。服务器和设备使用 HTTPS；不绕过证书验证。
- Rendezvous 不携带手机的访问令牌、不跟随重定向，使用 ETag 做条件读写并限制消息大小及等待时间。
- Rendezvous PUT 使用 `bodyBytes = utf8.encode(...)` 保留严格的 `Content-Type: text/plain`。Dart 的 `Request.body` 会自动添加 `charset=utf-8`，Synapse 会以 `400 M_INVALID_PARAM / Content-Type must be text/plain` 拒绝，导致扫码在握手前失败；刷新二维码不能修复此请求头问题。需安装包含此修复的新手机包。
- 安全通道使用 X25519、HKDF-SHA512、方向独立的 ChaCha20-Poly1305 密钥和 nonce，与 vodozemac 实际实现互通。
- 旧标准模式的授权链接 origin 必须匹配当前手机账号服务器公布的 issuer。用户明确核对校验码后才能打开授权。
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

本次本机验证：23 项协议／界面测试通过，包含真实 JavaScript SDK + Rust ECIES peer 的握手、校验码、设备授权、完整密钥消息及 SAS 交接互通。界面测试验证恢复失败重试、取消、超时、浏览器打开失败、中文 320×568 布局。测试中采用人工账号和浏览器授权响应，没有使用真实账号或访问真实认证服务。

完整工程 `flutter build web --no-pub` 已通过。Android/iOS 摄像头实机扫码、真实服务器授权与备份恢复仍需实机联调。本机缺少 Android SDK，移动端包使用仓库现有 GitHub Actions 构建。`Build Mobile Packages` 已增加前置 QR 登录校验，包含真实 JS SDK peer。修改源码不会更新手机上已经安装的旧客户端，需要重新构建安装。

## 3.0.5 回归范围

恢复页立即显示缓存设备，单独查询本账号公钥，不再等待所有加密房间成员查询。保留 SDK 的设备签名、密钥更换与已见设备检查；仅列出设备不会赋予信任。查询超时保留密钥输入和缓存设备，延迟同步可自动补齐列表，超时显示本地化连接提示。

电脑注销前再次核对 whoami 的账号及设备绑定；取消扫码也只撤销确认属于新电脑的令牌。离线测试使用真实 SDK 验证独立令牌与当前会话注销；不能据此认定已解决真实服务器上的手机连带登出，仍需实机验证。

自动恢复回归使用真实 Rust 引擎：不含 master seed 的身份信任、电脑签名、备份密钥导入，下载并恢复真实 Megolm 会话，解密原本无法读取的测试消息；另覆盖身份变化、备份版本变化、错误目的设备、取消与私钥替换。
