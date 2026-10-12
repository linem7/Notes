# Notes v1 架构

> 本文说明 v1 怎么实现。功能规格见 [`SPEC.md`](SPEC.md)，术语见 [`CONTEXT.md`](../CONTEXT.md)，关键取舍见 [`docs/adr/`](adr/)。
>
> 很多部分直接移植 [linem7/Chatbot](https://github.com/linem7/Chatbot)（下称 Chatbot）。移植时以 Chatbot `main` 上的代码为准，改名（`Chatbot` → `Notes`）、删掉 Notes 用不到的部分（Anthropic、Gemini、Web Search、Citation、多轮对话），保留它的测试并一起移植。

## 1. 工程基线

| 项 | 决定 |
|---|---|
| 平台 | macOS 26 Tahoe 及以上，Apple Silicon |
| 语言 | Swift 6 语言模式，严格并发检查 |
| UI | SwiftUI 为主；Board、Quick Add 窗口、Hotkey、网页抓取用 AppKit / WebKit |
| 工程 | XcodeGen：只提交 `project.yml`，`.xcodeproj` 在 `.gitignore` |
| 测试 | Swift Testing；`NotesCore` 可以 `swift test` 单独运行 |
| 依赖（SPM） | App：`sindresorhus/KeyboardShortcuts`（3.x）、`gonzalezreal/swift-markdown-ui`（2.4.1 起，product `MarkdownUI`）。NotesCore：`groue/GRDB.swift`（7.x）。网页正文抽取用打包进 App 资源的 Mozilla [Readability.js](https://github.com/mozilla/readability)（Apache-2.0，固定一个 release 版本，文件头保留许可证） |
| 不引入 | LLM SDK、SSE 库、Sparkle、HTML 解析库 |
| bundle id | `com.linem7.Notes` |
| 签名 | 固定自签名证书 `Notes Self-Signed`（ADR-0004）；CI 不签名 |
| CI | `.github/workflows/ci.yml`，macos-26 runner，同 Chatbot：生成工程 → 构建 App（不签名）→ `swift test --package-path Packages/NotesCore` |
| 日志 | `os.Logger`，不记录 key 和 Note 内容 |

## 2. 模块划分

```
project.yml
App/                          # app target「Notes」
  NotesApp.swift              # @main：MenuBarExtra + Settings scene，LSUIElement = true
  AppDelegate.swift           # 持有 Hotkey、BoardController、QuickAddController、每日清理定时器、午夜重分组定时器
  Board/                      # BoardWindow（NSPanel 子类）、BoardController、BoardView、NoteRow、NoteEditor、MaterialChip
  QuickAdd/                   # QuickAddPanel（移植 Chatbot QuickPanel）、QuickAddController、QuickAddView、
                              #   ComposerTextView（移植）、DraftCard、QuickAddStore（@MainActor @Observable）
  Web/                        # WebPageFetcher：离屏 WKWebView 抓取 + Readability.js + createPDF
  System/                     # Hotkey（移植）、APIKeyStore（移植，service 改名）、LaunchAtLogin（移植）、
                              #   RegularWindows（移植）、MenuBarIcon、AppLanguage
  Settings/                   # General / Connection / Advanced（Connection 页移植并删掉非 OpenAI 兼容模板）
  Rendering/                  # MarkdownUI 主题（移植，去掉代码高亮）
  Resources/                  # Localizable.xcstrings（源语言 en，另有 zh-Hans）、Readability.js
Packages/NotesCore/           # 本地 SPM 包，不依赖 SwiftUI/AppKit/WebKit
  Sources/NotesCore/
    Domain/                   # Note、DueDate、Material、MaterialKind、Draft、Connection、Platform、ModelInfo、ChatError、JSONValue
    LLM/                      # SSEParser、HTTPTransport、OpenAICompatibleClient（移植并精简）
    Organize/                 # Organizer、OrganizePrompt、OrganizeResponseParser、MaterialBudget
    Intake/                   # MaterialIntake、PDFTextExtractor（移植）、TextDecoder、ImageOCR、LinkDetector
    Storage/                  # NoteStore（GRDB）、MaterialFiles、Cleanup
    Board/                    # BoardSections：分组和排序（纯函数，可测试）
  Sources/notes-debug/        # 命令行：用真实 key 跑一次 Organize（同 chatbot-debug）
  Tests/NotesCoreTests/       # 含 Fixtures/
```

依赖方向：`App → NotesCore`。`NotesCore` 可以用 PDFKit、Vision、ImageIO（`#if canImport` 隔开，相关测试只在 CI 跑），不能用 SwiftUI、AppKit、WebKit。

## 3. 数据模型与存储

### 3.1 领域类型

```swift
struct DueDate: Codable, Hashable, Sendable {
    var day: String      // 本地日历日 "yyyy-MM-dd"，不随时区漂移
    var time: String?    // "HH:mm"，可选
}

struct Note: Identifiable, Sendable {
    var id: UUID
    var title: String
    var due: DueDate?
    var detail: String            // Markdown
    var doneAt: Date?             // nil = 未完成
    var createdAt: Date
    var updatedAt: Date
}

enum MaterialKind: String, Codable, Sendable { case source, file, webPage }

struct Material: Identifiable, Sendable {
    var id: UUID
    var noteID: UUID
    var kind: MaterialKind
    var displayName: String       // 文件名 / 网页标题（抓取失败时是 URL）/ "Source"
    var storedFile: String?       // materials/files/ 下的文件名：File 的副本、Source 的 .txt（可被多条 Material 共用）
    var url: String?              // Web Page
    var textFile: String?         // Web Page 抽出的正文 .txt
    var snapshotFile: String?     // Web Page 的 PDF 快照
    var createdAt: Date
}
```

### 3.2 数据库

位置：`~/Library/Application Support/com.linem7.Notes/notes.sqlite`，GRDB，迁移从 v1 开始。

```
note(id TEXT PK, title, dueDay TEXT?, dueTime TEXT?, detail, doneAt REAL?, createdAt REAL, updatedAt REAL)
material(id TEXT PK, noteID → note ON DELETE CASCADE, kind, displayName, storedFile?, url?, textFile?, snapshotFile?, createdAt REAL)
```

- 时间列存 `timeIntervalSinceReferenceDate`（同 Chatbot）。
- `NoteStore` 提供：`allNotes()`、`observe()`（GRDB `ValueObservation`，Board 订阅）、`insert(notes:materials:)`（一个事务）、`update(note)`（只写 title / due / detail，完成状态只经 `setDone`）、`setDone(id, at:)`、`delete(id)`、`addMaterial(noteID:from:)`（把文件写进 `materials/files/` 并插入 File 记录）、`addMaterial(_ material:)`（文件已在 `materials/files/` 里的记录，Source、Web Page 和共享的 File 用）、`deleteMaterial`、`deleteExpiredDone(now:)`、`deleteAllDone()`、`referencedFileNames()`。
- 删除 Note 时只删记录（material 级联删除），然后调用 `MaterialFiles.collectGarbage(referenced:)` 删掉不再被任何 material 行引用的文件（§3.3）。启动时也跑一次。
- 没有全文搜索（v1 不做搜索）。

### 3.3 Material 文件（共享存储，2026-10-12 用户决定）

- 所有 Material 的文件都放在同一个目录 `materials/files/`，不再按 Note 分目录：
  - File 副本：`<fileID>.<原扩展名>`（bundle 目录如 `.pages` 也按原样复制）；
  - Source：`<fileID>-source.txt`；
  - Web Page：`<fileID>.txt`（正文）和 `<fileID>.pdf`（快照）。
- `fileID` 是保存时新生成的 UUID，和 Material 的 id 无关。**同一次保存里，一个 staging 文件只写进 `files/` 一次**；一次 Organize 拆成多条 Note 时，各条的 Material 行（各自的 id、各自的 noteID）引用同一个文件名。同一份 Source 和同一个 Web Page 的正文、快照同理。
- 往已有 Note 拖入的 File 也写进 `files/`，引用计数为 1。
- **删除只删行，不直接删文件**。文件由 `collectGarbage(referenced: Set<String>)` 回收：列出 `files/` 下的所有条目，删掉不在 `referenced`（所有 material 行的 storedFile / textFile / snapshotFile 的并集）里的。调用时机：删除 Note、删除单个 Material、30 天清理、删除所有已完成 Note 之后，以及启动时。`NoteStore` 提供 `referencedFileNames()`。
- 写入顺序：先写文件，再在一个事务里插入记录；事务失败时，刚写的文件会在下一次 collectGarbage 时被回收，不会留下指向不存在文件的记录。
- Quick Add 期间加入的 File 先复制到 `staging/<sessionID>/`，保存后删掉 staging。启动时清空 `staging/`。
- 迁移：v1 尚未发布，直接改 #14 合入的 `MaterialFiles`（去掉按 Note 分目录的 `directory(for:)`、`removeNoteDirectory`、`removeFiles(of:)`），不需要数据迁移。

## 4. Organize

### 4.1 输入组装（`MaterialBudget` + `OrganizePrompt`）

用户消息按顺序拼成一段文字：

```
<input>
用户粘贴或输入的原文
</input>

<material index="1" kind="file" name="合同.pdf">
Readable Text……
</material>
<material index="2" kind="webpage" url="https://…" title="…">
正文……
</material>
<material index="3" kind="file" name="报价.xlsx" readable="false"/>
```

- 上限（字符数，L2，可以以后调）：单个 Material 20,000；所有 Material 合计 60,000；原文 20,000。超出的截断，并在末尾写 `（后文已截断 / truncated）`。
- system prompt = 第一行「Today is 2026-10-12 (Monday), time zone Asia/Shanghai.」+ 用户可编辑的 Organize prompt（默认内容见 `OrganizePrompt.default`，要求见 SPEC §4）。

### 4.2 模型调用

- 移植 Chatbot 的 `SSEParser`、`HTTPTransport`、`OpenAICompatibleAdapter` 的请求编码、关闭思考字段（按 Platform）、错误映射和 `/models` 拉取，合成一个 `OpenAICompatibleClient`。去掉 tools、web search、citation、图片输入、多轮历史。
- 仍用流式（`stream: true`），收齐全文再解析：保留 Chatbot 的空闲超时、取消和 `[DONE]` 前断流判 network 的逻辑；Quick Add 上可以显示已收到的字数作为进度。
- Platform 是 DeepSeek 官方或 OpenRouter 时发 `response_format: {"type": "json_object"}`；其他 Platform 不发，靠 prompt 约束。
- `temperature` 不发（用默认值）。

### 4.3 输出格式和解析（`OrganizeResponseParser`）

模型输出：

```json
{
  "notes": [
    {
      "title": "Send the signed contract to Alex",
      "due": "2026-10-15",
      "time": "15:00",
      "detail": "- Sign page 3\n- Email to alex@example.com",
      "materials": [1, 2]
    }
  ]
}
```

- 宽松解析：去掉 ```` ```json ```` 围栏；取第一个 `{` 到最后一个 `}`；`due`、`time` 格式不对就当空；`materials` 缺失或为空表示「全部 Material」，越界的序号丢弃；`title` 为空的条目丢弃；`notes` 为空数组时生成一条 fallback。
- 解析失败：fallback 为一条 Draft，Title = 输入第一行（最多 80 字符），Detail = 模型原文，挂全部 Material。
- 结果是 `[Draft]`，`Draft` 有 `title`、`due`、`detail`、`materialIndices`、`isSelected`。

## 5. Intake（`MaterialIntake`）

- 输入：文件 URL、图片数据（剪贴板）、URL 字符串。输出：`StagedMaterial`（kind、displayName、staging 路径或 URL、`readableText` 的异步状态：pending / ready(String) / unavailable(reason)）。
- **按内容分类**（参考 Chatbot `AttachmentIntake`）：
  - 扩展名是 pdf → `PDFTextExtractor`（移植）；全部页抽出来是空的 → 用 PDFKit 把每页渲染成图片走 `ImageOCR`（最多 30 页）；
  - 图片扩展名（png jpg jpeg heic gif webp tiff bmp）→ `ImageOCR`：Vision `VNRecognizeTextRequest`，`recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]`，`.accurate`，开 `usesLanguageCorrection`；
  - 前 8KB 没有 NUL 字节、能按 UTF-8 / BOM / 系统编码检测解码 → 文本（移植 Chatbot 的解码逻辑）；
  - 其他（含 Office 文档、bundle 目录如 `.pages`）→ `unavailable(.notReadable)`，照样存。
- 剪贴板图片数据存成 `Pasted Image <时间>.png`。
- `LinkDetector`：用 `NSDataDetector` 找 http/https 链接，去重，按出现顺序取前 5 个。

## 6. 网页抓取（App/Web/`WebPageFetcher`）

- 离屏 `WKWebView`（`WKWebsiteDataStore.nonPersistent()`，不带用户的 cookie），加载 URL，等 `didFinish` 后再等 1 秒给前端渲染，单个链接总超时 20 秒，最多同时抓 2 个。
- 注入打包的 `Readability.js`，执行 `new Readability(document.cloneNode(true)).parse()`，取 `title` 和 `textContent`；失败或正文少于 200 字符时退回 `document.body.innerText`。
- PDF 快照：`WKWebView.createPDF(configuration:)`，失败不影响正文。
- 结果：`WebPageResult(title, text, pdfData?)`；整体失败时 Material 仍保存 URL，Readable Text 为 unavailable（原因：「Couldn't load the page」）。
- 需要登录的页面（比如部分微信公众号文章）可能抓到登录页，v1 不处理，只靠「正文太短」退回 innerText。**需要真机核实微信公众号链接的效果。**
- 在主线程使用 WebKit；对外是 `async` 接口，由 `QuickAddStore` 调用。NotesCore 里定义协议 `WebPageFetching`，App 注入实现，方便测试 Intake 流程。

## 7. Board

- `BoardWindow`：`NSPanel` 子类，`.borderless` + `.resizable` + `.fullSizeContentView`，`canBecomeKey = true`，内容是 `NSHostingView(BoardView)`，背景用 `NSVisualEffectView` / SwiftUI material，大圆角。
- **Board Mode**：
  - On Desktop：`level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)`，`collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`。在桌面图标之上、普通窗口之下；「显示桌面」时不被推开（`.stationary`）。**需要真机核实**：这个层级下能否正常点击、编辑文字、拖动、调整大小；不行时退回 `kCGDesktopWindowLevel` 附近的其他层级，记录到 issue。
  - On Top：`level = .floating`，`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]`。
- 位置和大小用 `setFrameAutosaveName("Board")` 持久化；Board Mode 和是否显示存 UserDefaults。
- 顶栏空当用 `NSWindow.performDrag(with:)` 拖动（同 Chatbot #63）。
- `BoardSections`（NotesCore，纯函数）：输入 `[Note]` 和「今天」，输出分组和排序（SPEC §2.2）。用 `Calendar.current` 和本地时区判断今天。
- 午夜重分组：AppDelegate 在下一个本地午夜（`NSCalendarDayChanged` 通知）刷新「今天」。
- Markdown：MarkdownUI，主题移植 Chatbot 的 `MarkdownTheme` 并缩小字号；链接通过 `OpenURLAction` 用默认浏览器打开。
- 打开 Material：`NSWorkspace.shared.open(fileURL)`；Source 和网页正文在行内展开显示。

## 8. Quick Add

- 移植 Chatbot 的 `QuickPanel`（`.nonactivatingPanel` + `.borderless`、`level = .floating`、失焦隐藏、`performDrag`、偏上居中定位）、`QuickPanelController` 和 `ComposerTextView`（⏎ / ⇧⏎ / 输入法组字处理），把快捷键表换成 SPEC §3.4；去掉「固定」图钉。
- `QuickAddStore`（`@MainActor @Observable`）：`inputText`、`materials: [StagedMaterial]`、`phase`（idle / organizing / drafts([Draft]) / failed(ChatError)）、`organizeTask`。
- Organize：等待所有 pending 的 Readable Text 完成（最多 30 秒，超时的当 unavailable）后组装请求。
- 保存：每个 staging 文件只写一次到 `materials/files/`，生成 Note 和 Material 记录（多条 Note 引用同一文件名），写 Source（原文 .txt），Web Page 写正文和快照，一个事务插入；成功后清空 store、删 staging、隐藏面板，通知 Board 高亮新 Note。
- 打开文件面板时的激活处理同 Chatbot（`yieldActivation`）。

## 9. 系统集成

- **Hotkey**：KeyboardShortcuts，名字 `.quickAdd`，默认 option+N；冲突检测同 Chatbot。不做「连按两次 ⌘」。
- **菜单栏**：`MenuBarExtra`，label 是图标加数字（今天到期 + 逾期的未完成数量）。
- **界面语言**（`AppLanguage`）：首次启动时若 `UserDefaults.standard.object(forKey: "AppleLanguages")` 不是 app 自己写过的（用 `didSetInitialLanguage` 标记），写入 `["en"]`；设置里切换时写 `["en"]` 或 `["zh-Hans"]`，然后提示重启，「Relaunch」按钮用 `NSWorkspace.openApplication` 启动新实例后退出自己。
- **API key**：Keychain service `com.linem7.Notes.apikey`，account 为 Connection ID（移植 `APIKeyStore`）。
- **开机启动**：`SMAppService.mainApp`（移植）。
- **普通窗口**（设置）：移植 `RegularWindows`，打开时 `.regular`，关掉后 `.accessory`。
- **清理**：启动时和每 24 小时调用 `NoteStore.deleteExpiredDone(now:)`（完成 30 天以上），以及清 staging 和 `collectGarbage`。`collectGarbage` 对修改时间在 10 分钟内的文件有宽限期：保存 Note 时先写文件再插记录，不能把刚写下、记录还没插入的文件当成无人引用误删。清 staging 时，每 24 小时那次同样跳过 10 分钟内改过的会话目录（读到「正在用的会话」之后用户可能又粘贴了文件）；启动时那次全部清掉。

## 10. 需要真机核实的事

1. 桌面层级的 Board 能否点击、编辑、拖动、调大小，「显示桌面」和 Stage Manager 下的表现（§7）。
2. `deepseek-flash` 关闭思考后的速度，以及 `response_format: json_object` 的稳定性。
3. 微信公众号、WhatsApp 网页链接等的抓取效果（§6）。
4. Vision OCR 对微信聊天截图的中文识别效果。
5. option+N 在中文输入法下能否触发。

## 11. 实现顺序（对应 issue）

1. 工程骨架：`project.yml`、App 和 NotesCore 空壳、CI、`scripts/install.sh`、`scripts/package-release.sh`、README 构建说明。
2. NotesCore 存储：Domain、NoteStore、MaterialFiles、清理、BoardSections。
3. NotesCore 模型调用：移植 SSE、HTTPTransport、OpenAI 兼容客户端、Platform、Connection、`/models`。
4. NotesCore Intake：PDF、文本、OCR、LinkDetector、MaterialBudget。
5. NotesCore Organize：prompt、请求组装、响应解析、notes-debug。
6. App 网页抓取：WebPageFetcher + Readability.js。
7. App Board。
8. App Quick Add（Hotkey、面板、Draft、保存）。
9. App 菜单栏、设置、首次启动、语言切换、开机启动。
10. 测试补齐、INSTALL.md、v0.1.0 打包说明。
