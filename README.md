# AppleMailAI — macOS 原生 Apple Mail AI 扩展（v1.1）

基于 **Swift 6 + MailKit + SwiftUI** 构建的 macOS 14.0+ 原生 Apple Mail 扩展与配套宿主应用。支持 **多 AI 服务商与 SSE 实时流式呈现**、**Outlook KB 历史报价只读比价参考**、**基于安全作用域书签的附件智能归档（Dry-Run）**，以及 Apple Mail 原生毛玻璃（Vibrancy）与 7 色自动旗标联动。

## v1.1 核心能力

1. **多 AI 服务商抽象与实时流式分析（`AIProviderStore` + `AIServiceClient` + `PartialEmailAnalysisExtractor`）**
   - 原生支持四大类接口与一键预设，并可自由增删自定义配置：
     - **Vertex AI (Google Cloud)**：`locations/global`（支持 `gemini-3.8-flash` / `gemini-4-carbon`）
     - **Gemini Developer API**（AI Studio）：`gemini-2.5-flash` / `gemini-2.5-pro`
     - **OpenAI 兼容接口**：内置 OpenAI、DeepSeek、OpenRouter 预设，也支持任意 `/v1/chat/completions` 自建网关（Ollama / vLLM / LiteLLM 等）
     - **Anthropic Claude**：`/v1/messages`（`claude-3-5-haiku-latest` / `claude-sonnet-4-20250514`）
   - 统一抽象 **`⚡ 极速主力 (fast)`** 与 **`🧠 深度推理 (deep)`** 两档模型，可在阅读/写信面板顶部胶囊菜单一键切换档位或切换服务商。
   - **SSE 实时流式解析**：分析时按字段顺序增量提取 `headline`、`suggestedFlag`、`coreConclusions` 与 `plainChineseTranslation`，首字即刻渐进呈现（若上游返回非流式 JSON 则自动无缝降级）。
   - **语义重点高亮（`MailHighlightedText`）**：自动渲染 `==重点结论==`（浅色/深色 Aqua 自适应琥珀高光）、`**加粗**` 与 `` `SKU/单价/标准号` `` 等宽芯片；并支持从 v1.0.0 Keychain / UserDefaults 配置无缝迁移。

2. **Outlook KB 历史报价参考（`HistoricalPriceLookupService`，严格只读）**
   - 打开邮件时在后台并发提取候选 Moxa 料号（如 `TN-4908-4GTX-WV-CT-T`、`EDS-4012-8GT4XS-HV-T`、`NPort 5610-8-DT-J`、`SFP-1GLXLC-T` 等）并识别商务询价意图。
   - 使用 C `SQLite3` URI `file:...?mode=ro&immutable=1`（`SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`）只读查询本机运行时缓存 `~/.cache/moxa-kb-runtime/outlook.sqlite`（**绝不直接打开 `.moxa-kb/*.sqlite` 冷库**，若无本地库则优雅隐藏卡片，不影响开源用户开箱即用）。
   - 展示型号价格区间、币种、含税/未税（`taxMode`）、报价类型（`特价支持` / `报价` / `订单价` 等）、客户/项目/日期、`精确型号` vs `同系列参考` 标签，以及一键跳回 Apple Mail 原报价邮件（`message://`）。

3. **邮件附件本地提取与智能归档（`MIMEAttachmentExtractor` + `WorkspaceBookmarkStore` + `AttachmentOrganizerService`）**
   - 在 `MEMessageSecurityHandler` 本地解析邮件时，仅对含非内嵌附件的邮件在内存中缓存原始 MIME 字节（10 封 / 40 MB 有界 LRU，`RawEmailDataStore`），不上传任何附件二进制内容。
   - 通过 **「整理归档…」** 或单附件按钮打开 **Dry-Run 归档预览面板**：
     - 首次需由用户通过 `NSOpenPanel` 显式授权工作区根目录（如 `~/Documents/Moxa`），并以 `com.apple.security.files.bookmarks.app-scope` 安全作用域书签持久化。
     - 结合工作区真实 2 级目录扫描（+ 可选只读 `~/.cache/moxa-kb-runtime/moxa_kb.sqlite` 线索）进行确定性打分，并可选调用当前 AI 服务商在 Top 25 候选目录内辅助路由（5 秒超时自动回退）。
     - 写入前支持勾选/取消、候选目录 `Menu` 选择、手动编辑相对子目录与文件名，并实时检测碰撞状态（新建保存 / **SHA-256 内容相同自动跳过** / **同名异构自动追加日期或序号**）。
     - 点击 **「确认归档保存」** 后经路径红线校验（拒绝 `..`、绝对路径、隐藏 `.moxa-kb` 目录及符号链接逃逸），使用 `renamex_np(..., RENAME_EXCL)` 原子写入，**绝不覆盖已有文件**，支持 **「在 Finder 中显示」**。

4. **邮件阅读横幅、后台 7 色旗标、提醒事项联动与双语写信助手（v1.0.0 核心保留）**
   - **阅读横幅（`MEMessageSecurityHandler`）**：纯本地 CPU 解析 RFC 5322 正文与引用链（自动剥离尾部保密免责声明），S/MIME 与 PGP 加密信封原样退还 Mail 原生解密；25 MB 以内原文原样透传，**绝不加密、绝不篡改原信**。
   - **Moxa Primary 后台预分析与 7 色自动旗标（`MEMessageActionHandler`）**：自动识别 48 小时内 Moxa 收件邮件并调用当前服务商 `fast` 档位预缓存，按规则自动打 7 色旗标（`紧急待回` / `等审批` / `跟报价` / `重点项目` / `技术卡点` / `产品变更` / `发票报销`）。
   - **苹果「提醒事项 (Reminders)」一键联动（`EventKit`）**：待办右侧 `+` 一键写入「Moxa 邮件待办」，附带 `message://` 原信跳转链接。
   - **写信窗口双语回复助手（`MEComposeSessionHandler`）**：读取原信上下文，结合快捷意图与语气生成中英双语草稿。

## 开源部署与配置指南

### 1. 构建、测试与安装

1. 如需本机代码签名，可复制 `Config/LocalSigning.xcconfig.example` 为 `Config/LocalSigning.xcconfig`（已被 `.gitignore` 忽略），填入自己的 `DEVELOPMENT_TEAM` 与证书信息。
2. 运行构建、测试与安装：

```bash
# 1. 生成 Xcode 工程并运行全部单元测试（含 SQLite3 链接）
make test

# 2. 构建 Release 并安装到 ~/Applications + 注册 PlugInKit 扩展
make install

# 3. 验证签名与沙盒 Entitlements
make verify-sign

# 4. 运维诊断（检查签名、PlugInKit 重复注册、图标资源、Mail 崩溃日志与统一日志）
make diagnose

# 5. 实时查看扩展运行日志
make logs
```

### 2. 配置任意 AI 服务商（Vertex AI / Gemini / OpenAI / DeepSeek / OpenRouter / Claude / 本地模型）

1. 启动一次 `/Applications` 或 `~/Applications` 中的 **`AppleMailAI.app`**（或在 Apple Mail 扩展面板点击右上角 ⚙️ 齿轮图标）。
2. 在 **「AI 服务商配置」** 卡片中：
   - 点击 **「+ 添加」** 选择内置预设（**Vertex AI**、**Gemini Developer API**、**OpenAI**、**DeepSeek**、**OpenRouter**、**Anthropic Claude**）或新建自定义配置。
   - 填写对应的 `Base URL`、`极速模型 (fastModel)`、`深度模型 (deepModel)`；若使用 Vertex AI，还需填写 `GCP Project ID` 与区域（默认 `global`）。
   - 在 **「API Key 凭据」** 中粘贴密钥并点击 **「保存到 Keychain」**（所有密钥仅保存在本机 macOS Login Keychain，按配置 ID 隔离存储；默认 Vertex 配置向后兼容旧版 `vertex-api-key` 账号）。
   - 点击 **「测试连通性（极速）」** / **「测试深度模型」** 验证请求正常。
3. 若使用本地自建模型（如 Ollama / vLLM / LM Studio），选择 **OpenAI 兼容接口**，将 `Base URL` 设为本地地址（如 `http://127.0.0.1:11434/v1`），填入模型名称与任意占位 API Key 即可。
4. （可选）通过 `gcloud` 将 Vertex AI API Key 快速同步到 Keychain：
   ```bash
   GCP_PROJECT_ID=<your-project-id> GCP_API_KEY_UID=<your-api-key-uid> make provision-key
   ```

### 3. 权限、沙盒与隐私边界

宿主 App (`Config/HostApp.entitlements`) 与 MailKit 扩展 (`Config/Extension.entitlements`) 均启用 App Sandbox，包含：
- `com.apple.security.network.client`：直连所选 AI 服务商接口
- `com.apple.security.files.user-selected.read-write` + `com.apple.security.files.bookmarks.app-scope`：仅在用户通过系统文件对话框选定目录并点击确认后保存附件
- `com.apple.security.temporary-exception.files.home-relative-path.read-only` (`/.cache/moxa-kb-runtime/`)：可选只读访问本地运行时 SQLite 缓存（无缓存文件时自动降级为纯 AI + 实时工作区目录扫描）
- `com.apple.security.personal-information.calendars`：写入苹果「提醒事项」

## 运维开关与按钮位置

- **阅读邮件界面**：MailKit 入口位于**邮件正文顶部的横幅**（「AI 汇总分析」按钮）。
- **写信 / 回复界面**：扩展图标（`ComposeToolbarIcon`）位于**写信窗口顶部工具栏**（若工具栏较窄可能在右侧 `>>` 折叠菜单中）。
- **后台自动分析 / 打标开关**：
  ```bash
  defaults write com.bao3.AppleMailAI.Extension com.bao3.AppleMailAI.autoAnalyzeMoxaPrimary -bool false
  defaults write com.bao3.AppleMailAI.Extension com.bao3.AppleMailAI.autoFlagMoxaPrimary -bool false
  ```
- **紧急熔断开关（关闭阅读横幅、仅保留写信助手）**：
  ```bash
  defaults write com.bao3.AppleMailAI.Extension com.bao3.AppleMailAI.disableSecurityBanner -bool true
  # 恢复：defaults delete com.bao3.AppleMailAI.Extension com.bao3.AppleMailAI.disableSecurityBanner
  ```
