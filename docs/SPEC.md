# Notes v1 功能规格

> 本文是 2026-10-12 grilling 的结论，是 v1 实现的依据。术语以 [`CONTEXT.md`](../CONTEXT.md) 为准，实现方案见 [`ARCHITECTURE.md`](ARCHITECTURE.md)，关键取舍见 [`docs/adr/`](adr/)。
>
> 产品定位：**随手记下要做的事，执行时一眼看到**。在 WhatsApp、微信里看到一件事，或者突然想到一件事，复制对话、拖个文件、或者直接打一句话，模型整理成一条简单清楚的 Note。追求**快**，不追求精准：不开模型思考，用户随时可以手改。
>
> 参考项目：[linem7/Chatbot](https://github.com/linem7/Chatbot)。工程规范、外观风格、模型接入、分发方式都沿用它，下文写「同 Chatbot」的地方以 Chatbot 的 SPEC 和实现为准。

## 1. 形态

- **菜单栏常驻**，不出现在 Dock 和 ⌘Tab 里；设置窗口打开时临时出现在 Dock 和 ⌘Tab，关掉后恢复（同 Chatbot）。
- 两个主要界面：
  - **Board**：固定在桌面上的看板，单列列出所有 Note（§2）。
  - **Quick Add**：按 Hotkey 唤起的浮动面板，用来添加 Note（§3）。
- 设置窗口：标准 macOS 设置窗口，cmd+, 打开（§7）。
- 菜单栏图标：
  - 图标旁显示**今天到期 + 已逾期**的未完成 Note 数量，为 0 时不显示数字；
  - 菜单：New Note（打开 Quick Add）、Show Board、Board Mode（On Desktop / On Top 二选一）、Settings…、Quit Notes。
- **开机启动**，首次启动默认开启（同 Chatbot）。
- **不发系统通知**，不接日历，不做提醒。
- 最低 macOS 26，Apple Silicon。

## 2. Board

### 2.1 窗口
- 一个窄长的半透明面板（macOS 原生材质、大圆角，风格同 Chatbot），可以拖动、调整宽高；位置和大小**持久化**，重启后恢复。首次出现在主屏幕右侧。
- **Board Mode**（菜单栏切换，持久化）：
  - **On Desktop**（默认）：放在桌面层，像 Stickies 钉在桌面上。被其他窗口盖住；回到桌面（比如「显示桌面」手势）时可见。
  - **On Top**：始终在其他窗口上方。
- 出现在所有桌面空间（Space）里。
- 关掉 Board（顶栏的关闭按钮）只是隐藏，菜单栏 Show Board 重新显示；是否显示也持久化。

### 2.2 列表
- 顶栏：标题「Notes」、「+」按钮（打开 Quick Add）。
- 分组，从上到下：
  1. **Overdue**：Due Date 早于今天，红色日期；
  2. **Today**：Due Date 是今天，高亮；
  3. **Upcoming**：之后的日期；
  4. **No Date**：没有 Due Date；
  5. **Done**：已完成，默认折叠，标题显示数量。
- 组内排序：有日期的按 Due Date（再按时间，没有时间的排在同一天有时间的后面）升序；同一时刻按创建时间升序。No Date 按创建时间倒序。Done 按完成时间倒序。
- 空组不显示。整个 Board 为空时显示空状态：提示按 Hotkey 添加。
- 启动时数据库打不开（文件损坏等）：不弹窗，Board 上显示「Notes can't open its data」、原因，以及「Show in Finder」「Retry」两个按钮；此时 Quick Add 不能保存。
- 跨过午夜时自动重新分组（今天变成昨天的要进 Overdue）。

### 2.3 一条 Note
- **收起时**：完成勾选框、Title（一行，超出省略）、Due Date（相对写法：Today、Tomorrow、周几、具体日期；有时间时带时间）、Material 数量小图标。
- **点击展开**：
  - Detail：渲染 Markdown（标题、列表、链接、行内代码、粗体）；链接点击用默认浏览器打开；
  - Material 列表：每个一个小条，显示图标和名称，点击打开：
    - File：用系统默认 app 打开存储里的副本；
    - Web Page：点击打开原始 URL；旁边一个按钮打开本地 PDF 快照（快照失败时不显示），一个按钮查看抽出的正文；
    - Source：默认折叠，展开后在原地显示原文（纯文本、可选中复制）。
- **编辑**：展开后点「Edit」进入编辑：Title 单行、Due Date 日期选择器（可清除、可选时间）、Detail 多行纯文本（Markdown 源码）。可以删除单个 Material，也可以往已有 Note 拖入新的 File。⌘⏎、「Done Editing」或**失焦（点 Board 的别处、切到别的 app）都会保存**；Esc 放弃修改。
- **展开**：同时只展开一条 Note，展开另一条时前一条收起（正在编辑的先按失焦规则保存）。
- **保存失败**：数据库写入失败时，Board 上的值回到修改前，顶部出现一条红色的「Couldn't save」提示，约 4 秒后自动消失；编辑器保持打开、保留用户的输入，可以再次保存或按 Esc 放弃。不弹窗。
- **完成**：点勾选框立即进入 Done 区；在 Done 区取消勾选回到原组。
- **删除**：右键菜单 Delete，或点击选中这一行后按 ⌫（正在编辑文字时 ⌫ 只删字；只是展开不算选中）；不弹确认（同 Chatbot 的删除习惯）。连同 Material 一起删除。
- **自动清理**：完成超过 **30 天**的 Note 连同 Material 静默删除。app 启动时检查一次，之后每天一次。

## 3. Quick Add

### 3.1 唤起和外观
- Hotkey 默认 **option+N**，设置里可改（组合键，KeyboardShortcuts，不需要权限）。首次启动和改键时检测与系统快捷键的冲突，冲突时提示（同 Chatbot）。设置里静态提示：美式键盘上 option+N 原本用来输入 ñ，注册后这个组合不再打字。
- 也可以从菜单栏 New Note、Board 顶栏「+」打开。
- 浮动面板，不抢前台 app 的激活状态；出现在鼠标所在屏幕的偏上居中；顶栏空当可拖动，位置不持久化；能显示在全屏 app 上方（实现同 Chatbot 的 Quick Panel）。
- 再按 Hotkey、Esc、失焦都会隐藏面板。**Organize 进行中或有未保存的 Draft 时**，隐藏后再唤起保持原状；保存或清空后下次唤起是空白。
- 布局从上到下：
  1. 顶栏：「Quick Add」、当前 Model（「Connection / Model」，只显示，不在这里切换）；
  2. 输入区：多行输入框（粘贴文字、打字）；Material 条（每个加入的 File 和识别到的链接各一个小块，带 × 移除）；工具行：「+」选文件、提示「⏎ Organize · ⌘⏎ Save as is · ⇧⏎ New line」；
  3. Draft 区：Organize 之后出现（§3.3）。

### 3.2 输入
- **文字**：粘贴或输入。粘贴纯文字照常进入输入框。
- **File**：「+」、拖入、粘贴 Finder 里复制的文件、粘贴剪贴板里的图片数据（存成 PNG）。任何类型都收，数量不限。
- **链接**：输入框里出现的 http/https URL 自动识别成 Web Page Material，显示在 Material 条里，可以 × 移除（移除只是不抓取，文字照旧发给模型）。一次最多抓取前 5 个链接，多出的只当文字。
- **Readable Text 的来源**：
  | Material | Readable Text |
  |---|---|
  | PDF | 本地逐页抽取文字；抽不出（扫描版）时逐页 OCR |
  | 纯文本、Markdown、CSV、JSON、代码等（能按文本解码的） | 解码后的文字 |
  | 图片（PNG / JPEG / HEIC / GIF / WebP / TIFF） | 本地 OCR（Apple Vision，中英文） |
  | Web Page | 本地抓取网页、抽出正文 |
  | 其他（Word、Excel、PPT、压缩包……） | 无，只存；模型只看到文件名 |
- Readable Text 在加入时就开始准备，Material 小块上显示进度；失败的显示一个警告标记，悬停说明原因（抓不到网页、OCR 没有文字等），不阻止 Organize。

### 3.3 Organize 和 Draft
- **⏎**：Organize。把原文和所有 Material 的 Readable Text 交给 Default Model（§4），等待期间显示进度，可以按 ⌘. 或 Esc（面板保持）取消。
- 结果是 **1–N 条 Draft**，每条一张可编辑的卡片：勾选框（默认勾选）、Title、Due Date、Detail、它挂了哪些 Material（可以 × 去掉）。
- **⌘⏎**：
  - 已有 Draft 时，保存所有勾选的 Draft 为 Note，清空面板并隐藏；
  - 还没有 Draft 时，**跳过模型**，直接把输入保存成一条 Note：Title 是输入的第一行（最多 80 字符），Detail 是其余部分，没有 Due Date，所有 Material 都挂上，不生成 Source。
- 可以改了输入再按 ⏎ 重新 Organize：旧 Draft 立即清空（包括对它们的修改），中途取消也不恢复。
- 保存后 Board 上立刻出现新 Note，并短暂高亮。
- **Material 和 Draft 的对应**：模型为每条 Draft 指明它用到哪些 Material；没指明的默认全部挂上。每条 Draft 都挂一份 Source（原文）。同一个 File（以及同一份 Source、同一个 Web Page 的正文和快照）挂到多条 Note 时**只存一份**，几条 Note 共用；最后一条用到它的 Note 删除后才删文件。
- 输入只有 Material、没有文字时也可以 Organize。

### 3.4 面板内快捷键

| 按键 | 作用 |
|---|---|
| ⏎ | Organize（输入法组字时不触发） |
| ⇧⏎ | 换行 |
| ⌘⏎ | 保存 Draft；没有 Draft 时原样保存 |
| ⌘. | 取消 Organize |
| Esc | 隐藏面板（Organize 进行中时先取消） |

## 4. 模型

- **只支持 OpenAI 兼容协议**。Connection 模板：DeepSeek（默认）、OpenRouter、阿里云百炼、Custom（自填 base URL）。保存时拉取 Model 列表，同时就是连接测试；拉取失败可以手填模型 ID（同 Chatbot）。
- 默认 Model：**`deepseek-flash`**。
- **不开思考**：按 Platform 发关闭字段；关不掉的模型发它支持的最低档（同 Chatbot ADR-0002 的 OpenAI 兼容部分）。
- **不联网**：不开任何模型侧搜索。网页由 app 自己抓（§3.2）。
- API key 存 Keychain，**Notes 自己一份**，和 Chatbot 不共用。
- Organize 的要求（写进内置 system prompt，用户可以在设置里改、可以恢复默认）：
  - 用**输入的主要语言**写 Note（中文输入出中文，英文输入出英文）；
  - Title 一句话，动词开头，说清楚要做什么；
  - Detail 简短：几条要点；保留执行时需要的关键信息（人名、地点、数字、链接、要准备的东西）；不复述无关的聊天；
  - Due Date：从内容里读出截止时间，「下周三」「明天下午三点」这类说法按当前日期换算成具体日期；读不出就留空，**不要编**；
  - 一段输入里有几件独立的事就拆成几条，同一件事的子步骤写进 Detail；
  - 输出 JSON（格式见 ARCHITECTURE §4）。
- 当前日期、星期和时区不放在可编辑文本里，发送时由 app 加在 system prompt 最前面（同 Chatbot）。
- **Readable Text 超长时截断**：每个 Material 和总量都有上限（ARCHITECTURE §4），截掉的部分在发给模型的文字里标明「（后文已截断）」。存储里的原文不截断。
- 错误：同 Chatbot 的错误类别（key 无效、限流、过载、网络、上下文太长、接口原始错误），在 Draft 区显示，给出「重试」或「打开设置」。模型返回的 JSON 解析失败时，把模型原文作为一条 Draft 的 Detail，Title 用输入第一行，让用户手改，不报错。

## 5. 存储

- 全部在本地：`~/Library/Application Support/com.linem7.Notes/`
  - `notes.sqlite`：Note 和 Material 的记录；
  - `materials/files/`：File 的副本、Web Page 的正文和 PDF 快照、Source 原文。几条 Note 可以共用同一个文件。
- 删除 Note（手动或 30 天清理）后，没有任何 Note 再用到的文件随之删除。
- 不做 iCloud 同步、导出、导入。

## 6. 语言

- 界面语言：**默认英文**（不跟随系统），设置里可选简体中文。切换后提示重启生效，并提供「Relaunch」按钮。
- Note 的语言跟随输入（§4），和界面语言无关。

## 7. 设置

三个标签页：

**General**
- Hotkey（附冲突检测和 option+N 的静态提示）
- Language：English / 简体中文
- Board Mode：On Desktop / On Top（菜单栏或这里切换时，Board 若是隐藏的，会按新模式显示出来）
- Launch at Login（默认开）

**Connection**
- 增加、编辑、删除 Connection，模板见 §4；隐藏不用的 Model；拉取失败可手填模型 ID（同 Chatbot）。
- Default Model。

**Advanced**
- 编辑 Organize 的 system prompt，可以恢复默认。
- 打开数据目录（在 Finder 中显示）。
- 删除所有已完成的 Note（二次确认）。

## 8. 首次启动

- 把界面语言设为英文（只在第一次）。
- 打开设置窗口的 Connection 页，预选 DeepSeek 模板，粘贴 key 后 Save（同 Chatbot）。
- 显示 Board（On Desktop），开启 Launch at Login，检测 Hotkey 冲突。
- 没有 Connection 时按 ⏎ Organize：Draft 区提示「先添加 Connection」并给按钮；⌘⏎ 原样保存仍可用。

## 9. 分发

- 同 Chatbot：本机用固定自签名证书「Notes Self-Signed」构建 Apple Silicon Release，不公证，手动上传 ZIP 和 SHA-256 到 GitHub Release；不做自动更新。
- CI：push 到 main 和 PR 时在 macos-26 runner 上生成工程、构建（不签名）、跑 NotesCore 测试。

## 10. v1 明确不做

- 系统通知、提醒、日历集成、重复任务
- 模型思考、模型侧联网搜索
- 读取 Word、Excel、PPT 的内容（只存不读；以后按需加）
- 多个 Board、标签/分类、搜索、拖动排序
- iCloud 同步、导出导入、多设备
- Anthropic、Gemini 协议
- 桌面小组件（WidgetKit）、Mac App Store、App Sandbox
- 自动更新、tag 自动发布
