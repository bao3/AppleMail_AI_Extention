# AppleMailAI — macOS 原生 Apple Mail AI 扩展

基于 **Swift 6 + MailKit + SwiftUI** 构建的 macOS 原生 Apple Mail 扩展与配套宿主应用。

## 核心能力

1. **邮件阅读顶部横幅（`MEMessageSecurityHandler` + `MEDecodedMessageBanner` + `MEExtensionViewController`）**
   - 点开邮件时仅在本地纯 CPU 解析 RFC 5322 / MIME：提取当前正文、历史引用链、附件文件名/类型/大小（不发任何网络请求，不保留附件二进制字节）。
   - 遇到 `application/pkcs7-mime` 或 `multipart/encrypted` 加密邮件直接返回 `nil` 交还 Apple Mail 原生解密；普通邮件原样透传 `MEDecodedMessage.rawData`，**绝不加密、绝不篡改原信**。
   - 点击横幅按钮 **「AI 汇总分析」** 弹出原生 SwiftUI 面板，展示：
     - 核心结论（一句话总结 + 要点列表）
     - 待办事项（优先级、负责方、截止时间）
     - 项目 / 客户 / 型号 / 价格与交期要素
     - 英文通俗自然中译
     - 长信往来时间线
   - 按标准化 RFC 5322 `Message-ID`（SHA-256 键）自动进行本地磁盘缓存，再次打开同一封信秒开零费用，支持一键切换模型或强制重新分析。

2. **写信窗口工具栏助手（`MEComposeSessionHandler`）**
   - 点击写信窗口工具栏扩展图标，读取原信上下文（或手动补充摘要），结合快捷回复模板与语气选择，一键生成 **英文正文 / 中文正文 / 中英双语合并草稿** 及建议主题。

3. **Vertex AI 集成与 Keychain 安全**
   - 使用 Vertex AI `locations/global` Google 1P Gemini 模型：
     - 默认：`gemini-3.8-flash`（`⚡ Flash 3.8`）
     - 一键切换：`gemini-4-carbon`（`🧠 Carbon 4`）
   - API Key 仅存储在 macOS Login Keychain，**严禁写入任何代码或配置入库 Git**。
   - 宿主 App 与 `.appex` 均开启 App Sandbox 与 `com.apple.security.network.client`，使用本地 `Apple Development` 证书签名。

## 构建、测试与启用

1. 如需本机代码签名，可复制 `Config/LocalSigning.xcconfig.example` 为 `Config/LocalSigning.xcconfig`（已被 `.gitignore` 忽略），填入自己的 `DEVELOPMENT_TEAM` 与证书信息。
2. 构建、测试与安装：

```bash
# 1. 生成 Xcode 工程并运行单元测试
make test

# 2. 构建 Release 并安装到 ~/Applications + 注册 PlugInKit 扩展
make install

# 3. （可选）通过 gcloud 将自己的 Vertex AI API Key 写入本机 Keychain
GCP_PROJECT_ID=<your-project-id> GCP_API_KEY_UID=<your-api-key-uid> make provision-key

# 4. 运维诊断（检查签名、PlugInKit 重复注册、图标资源、Mail 崩溃日志与统一日志）
make diagnose

# 5. 实时查看扩展运行日志
make logs
```

在 **邮件 (Mail.app) → 设置… → 扩展** 中勾选启用 **AI 邮件汇总与双语回复**，然后启动一次 `AppleMailAI.app`，在配置面板中填入你自己的 GCP Project ID 与 Vertex AI API Key，并可进行零成本 `countTokens` 连通性校验及沙盒面板预览。

## 按钮位置与运维排查

- **阅读邮件界面**：MailKit 不支持向 Mail 主窗口工具栏添加按钮，阅读入口位于**邮件正文顶部的横幅**（「AI 汇总分析」按钮）。
- **写信 / 回复界面**：点击**新建邮件 / 回复 / 转发**后，扩展图标（`ComposeToolbarIcon`）会出现在**写信窗口顶部工具栏**（若工具栏较窄可能在右侧 `>>` 折叠菜单中，或右键工具栏 → **自定工具栏…** 拖出）。
- **紧急熔断开关（仅保留写信按钮、关闭阅读横幅）**：
  ```bash
  defaults write com.bao3.AppleMailAI.Extension com.bao3.AppleMailAI.disableSecurityBanner -bool true
  ```
  恢复：`defaults delete com.bao3.AppleMailAI.Extension com.bao3.AppleMailAI.disableSecurityBanner`

