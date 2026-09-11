# CodexPad — iPad 版本地代码 Agent

CodexPad 是一个原生 iPadOS SwiftUI 工程：用户先通过 **Files 文件夹选择器**授权一个项目目录，AI Agent 才能读取/修改该目录里的文件。

## 已实现

- 三栏界面：**项目文件树 / 代码编辑器 / Agent Chat**
- 文件夹授权与 security-scoped bookmark 持久化
- UTF-8 文件读取、编辑、保存、恢复；`⌘S` 保存
- Agent 工具：`list_directory`、`read_file`、`search_text`、`write_file`、`create_file`、`delete_file`、`move_file`
- 默认修改前显示 Diff，可 **Apply / Reject**；可在设置中启用 Auto Apply
- API Key 存 iOS Keychain，不写入工程和 UserDefaults
- API Base URL、模型、Reasoning 可修改；默认 `https://api.openai.com/v1` + `gpt-6-astra` + `high`
- 默认禁止 Agent 读取 `.env`、`.p8`、`.p12`、SSH 私钥、`.git` 等常见敏感文件
- 阻止绝对路径、`..` 越界和符号链接路径
- 新建文件不会覆盖同名现有文件；删除非空目录会拒绝
- 自带 App 图标与 Accent Color，无第三方依赖

## 在 Mac/Xcode 运行

1. 解压并打开 `CodexPad.xcodeproj`。
2. 在 **CodexPad Target → Signing & Capabilities** 选择你的 Apple Development Team。
3. 如有需要，把 Bundle ID `com.example.CodexPad` 改成你自己的。
4. 选择 iPadOS 18+ 真机或模拟器，Run。
5. App 内进入 **Settings** 保存 API Key，然后点 **Open Folder** 选择项目目录。

## Core 测试

项目根目录执行：

```bash
swift test
```

当前 Core 测试覆盖路径安全、敏感文件策略、Diff、严格 Tool Schema、Responses API 解析、Pending Change。

## iPadOS 本身的限制

这不是 iPad 上的完整桌面终端。iPadOS 不允许 App 随意遍历整个文件系统，也不给普通 App 一个任意命令执行环境。因此本版**不能本地运行** `git`、`xcodebuild`、npm/pip、shell 脚本或其他任意进程；它的核心能力是对用户授权项目目录进行 AI 辅助读取和编辑。

如果以后需要“像桌面 Codex 一样改完直接编译/测试”，下一版适合增加 **远程 Mac/CI Runner**：iPad 负责编辑和 Agent，Mac 负责 shell、build、test、git。

## 安全说明

- API Key 使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 存入 Keychain。
- Base URL 必须是 HTTPS。
- Auto Apply 会减少人工确认，开启前建议项目本身处于 Git/备份中。
- 如果要公开分发 App，建议把长期 API Key 改成后端签发的短期凭证。
