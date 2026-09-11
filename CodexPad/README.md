# CodexPad 3.1（4）

原生 iPadOS 18+ 编程工作区：项目文件、代码编辑器、智能助手与修改审查。
支持横竖屏、窄窗口、浅色与深色模式。无需第三方 UI 或 Agent 依赖。

## 使用

1. 打开项目文件夹，在系统文件选择器中授权目录。
2. 设置中填写 API Key 和 HTTPS API Base URL，输入停顿后自动保存检测，也可点击「保存并连接」或提交键盘输入。
3. 自动读取模型列表并验证 Responses 工具调用能力，无需选择模型。
4. 描述编程任务，审查 Diff，再逐项或全部接受、拒绝。

API Key 只存放在 Keychain。设置页不显示原始 Key，也不向模型发送 Key。
默认屏蔽 `.env`、私钥、证书、`.git`、`.ssh` 等敏感路径。
项目文件内容会按工具请求发送至用户配置的 API 服务，不会一次性上传整个项目。

## 已实现

- `UIDocumentPickerViewController(.folder, asCopy: false)`，选择回调立即进入加载状态。
- 会话持有 security scope；书签解析、生成、目录枚举与文件 I/O 不运行在主线程。
- 只扫描当前目录，展开时才读取子目录，避免被大型依赖树阻塞。
- 最近项目书签恢复，失效时显示中文错误及重新授权入口。
- 文件协调、操作取消、提供器等待超时、中文错误反馈。
- 文件读取及写入使用固定根目录描述符和 `openat/O_NOFOLLOW` 逐层约束路径。
- 创建拒绝同名覆盖；原子写入；保存、删除、移动前校验文件版本。
- UTF-8 编辑、未保存提示、切换文件及项目保护、Cmd+S、Cmd+F、原生查找替换。
- 文件及内容搜索；新建文件/目录、移动、重命名、删除上下文菜单。
- 十项工具：`list_directory`、`read_file`、`search_files`、`create_file`、
  `write_file`、`replace_text`、`move_file`、`rename_file`、`delete_file`、`create_directory`。
- 多工具调用完整处理，每项调用都有结果；支持批量审查和部分失败后的继续处理。
- 同批路径重叠拦截，外部修改冲突保护，编辑器与 Agent 写操作互斥。
- 无服务端对话存储的 Responses 请求，保留不透明推理项和全部工具输出。
- 最多 24 轮/80 次调用，分页读取、输出与上下文大小上限。
- 前后台切换、取消请求、项目/配置绑定，避免跨项目执行旧任务。
- 完整 iPad App Icon 和中文系统区域声明。

## 自动模型

模型列表来自实际 API 返回，不固定常规模型。按名称中的模型家族、版本、规模和编程特征排序，
再用无文件内容的小型 Responses function-call 探测验证候选。
列表不代表模型实际可调用，因此只缓存成功通过探测的模型。
缓存与 API 地址和 Key 的 SHA-256 指纹绑定，24 小时后自动重新检测。

当模型列表不可用，先尝试同一凭据的已验证缓存；OpenAI 可尝试发布时的引导别名，
其他网关尝试 `auto`、`default`。每个 fallback 必须通过真实工具调用验证才会保存。
401、429、服务端故障和网络故障不会被伪装成检测成功。
若网关既不提供模型列表，也不支持缓存或自动别名，客户端无法凭空推导其私有模型 ID，
会显示中文错误；本地文件编辑不受影响。

## 构建与测试

在 macOS 上：

```sh
swift test
xcodebuild clean build -project CodexPad.xcodeproj -scheme CodexPad \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=''
xcodebuild test -project CodexPad.xcodeproj -scheme CodexPad \
  -destination 'platform=iOS Simulator,name=<已安装的 iPad 模拟器>' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
```

单元和集成测试包括真实临时文件操作、中文路径、路径穿越、符号链接、
外部文件冲突、重复名称、二进制/大文件、搜索过滤、重复刷新、取消、
书签恢复、未保存保护、API 错误、JSON 协议、自动 fallback、凭据缓存隔离与批量审查。
UI 测试包括横屏编辑、未保存确认、中文设置、竖屏深色模式与系统文件选择器。
跨 App 文件夹用例使用独立的“授权测试源”App，验证读取、保存和重启恢复。
缺失测试提供器时测试失败，不再用自身目录或跳过结果代替外部授权验证。

仓库工作流 `.github/workflows/run-ipa-builder-newest.yml` 从根目录源码 ZIP 构建。
按顺序运行核心测试、Release unsigned IPA 构建、iPad UI 测试，再上传 IPA 和完整诊断。
ZIP 使用 `git archive` 生成，路径采用 POSIX 分隔符。

## 真实边界

- unsigned IPA 没有 Apple 签名，需要自行签名才能在正常 iPad 上安装。
- 没有本地 Shell、Git、npm、pip、xcodebuild 或任意命令执行；编译需远端 Mac/CI。
- 编辑器仅支持 UTF-8、2 MB 以内文本。大型文件仍可移动/删除，但不进入文本上下文。
- 单目录最多 5000 项，搜索最多 5000 项/100 个结果/15 秒；达到上限明确提示。
- 非空目录删除被禁止，目录移动最多检查 5000 项和 64 层。
- 所有符号链接均不读取。文件路径逃逸被拒绝，路径内的冒号和反斜线不接受。
- 文件协调能与合规的文档提供器协作，但不能承诺对不参与协调的第三方写入做跨进程事务。
- iCloud 下载、权限撤回与第三方文件提供器必须在实际设备和对应账号下进一步验收。
- 对话和未接受提议仅保留在当前进程；进入后台会停止运行中的助手，已落盘文件保留。
- 不内置真实 API Key；自动化网络测试使用 mock，不等同于用户账户的真实额度/模型验收。

更详细的根因与验证证据见 `docs/REPAIR-REPORT.md`。

3.1 追加修复了权限申请仍占用主线程、提供器不配合取消时旧超时无效、根目录提前打开的问题。
设置中的“文件夹访问诊断”可以查看、导出最近打开步骤。出现问题时请提供该记录与目录来源；
它不包含 API Key、文件内容或完整目录路径。
