# AppleMailAI — macOS 原生 Apple Mail AI 扩展

基于 **Swift 6 + MailKit + SwiftUI** 构建的 macOS 原生 Apple Mail 扩展与配套宿主应用。

## 核心能力

1. **邮件阅读顶部横幅（`MEMessageSecurityHandler` + `MEDecodedMessageBanner` + `MEExtensionViewController`）**
   - 点开邮件时仅在本地纯 CPU 解析 RFC 5322 / MIME：提取当前正文、历史引用链、附件文件名/类型/大小（不发任何网络请求，不保留附件二进制字节）。
   - 遇到 `application/pkcs7-mime` 或 `multipart/encrypted` 加密邮件直接返回 `nil` 交还 Apple Mail 原生解密；普通邮件原样透传 `MEDecodedMessage.rawData`（25 MB 以内），**绝不加密、绝不篡改原信**。
   - 点击横幅按钮 **「AI 汇总分析」** 弹出原生 Apple Mail 毛玻璃（`NSVisualEffectView`）风格面板，展示：
     - 核心结论（一句话总结 + 要点列表）与推荐旗标徽章
     - 待办事项（优先级、负责方、智能截止日预览，支持右侧 `+` 一键写入苹果「提醒事项」）
     - 项目 / 客户 / 型号 / 价格与交期要素
     - 英文通俗自然中译
     - 长信往来时间线
   - 按标准化 RFC 5322 `Message-ID`（SHA-256 键）自动进行本地磁盘缓存，再次打开同一封信秒开零费用，支持一键切换模型或强制重新分析。

2. **Moxa Primary 新邮件后台自动预分析与 7 色旗标自动分类（`MEMessageActionHandler`）**
   - 收到新邮件时由 MailKit 在后台自动唤醒扩展；若尚未下载正文且符合 **Moxa 邮箱 Primary** 条件（校验 Moxa Exchange Tenant / `@moxa.com` 收件人，过滤本人发送、系统机器人、订阅群发、日历回执与垃圾邮件，且收信时间在 48 小时内），自动返回 `.invokeAgainWithBody` 让 Apple Mail 下载完整正文后回调。
   - 后台自动调用 `gemini-3.8-flash`（零思考预算 `thinkingBudget: 0` 快速模式）完成分析并写入本地缓存；同时根据邮件内容自动匹配 7 色旗标（`紧急待回` / `等审批` / `跟报价` / `重点项目` / `技术卡点` / `产品变更` / `发票报销`）并写入 Apple Mail。
   - 可在扩展内 **设置面板** 中开关后台分析与 7 色自动打标，或通过终端 `defaults` 控制：
     ```bash
     # 关闭后台自动分析（设为 true 或删除键即可恢复）
     defaults write com.bao3.AppleMailAI.Extension com.bao3.AppleMailAI.autoAnalyzeMoxaPrimary -bool false
     # 关闭后台自动标记 7 色旗标（设为 true 或删除键即可恢复）
     defaults write com.bao3.AppleMailAI.Extension com.bao3.AppleMailAI.autoFlagMoxaPrimary -bool false
     ```

3. **苹果「提醒事项 (Reminders)」一键联动（`EventKit`）**
   - 在 AI 面板每条待办右侧点击 **`+`** 按钮即可直接写入系统「提醒事项」（默认归入「Moxa 邮件待办」列表）。
   - 若邮件提及具体任务时间，以邮件日期 `09:00` 为截止日并**提前 1 天提醒**；若未提及时间，默认以 **1 周后（`+7 天`）`09:00`** 作为截止日与提醒时间，并自动附带 `message://` 原信直达链接。

4. **写信窗口工具栏助手（`MEComposeSessionHandler`）**
   - 点击写信窗口工具栏扩展图标，读取原信上下文（或手动补充摘要），结合快捷回复模板与语气选择，一键生成 **英文正文 / 中文正文 / 中英双语合并草稿** 及建议主题。

5. **Vertex AI 集成与 Keychain 安全**
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

