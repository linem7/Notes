# Notes

一个 macOS 桌面上的任务便签：固定在桌面，或者按 Hotkey 唤起；把聊天记录、文件、网页链接或一句话交给模型，整理成一条简单清楚的 Note。

## Language

### 内容

**Note**:
一件要做的事。只有三个字段：Title、Due Date、Detail，外加完成状态和 Material。
_Avoid_: 任务卡、便签条、Todo、Card

**Title**:
Note 的一句话标题，说清楚要做什么。

**Due Date**:
Note 的截止日期。必须是一个日期（本地日历日），时间可选。没有截止日期的 Note 也允许。
_Avoid_: 提醒时间、Deadline（界面英文文案可以用 Due）

**Detail**:
Note 的正文，Markdown，通常是几条要点、相关链接和执行时需要的信息。
_Avoid_: 描述、备注、Body

**Done**:
Note 的完成状态。勾选后进入看板底部折叠的 Done 区，30 天后连同 Material 一起自动删除。

**Material**:
挂在 Note 上、执行任务时要回看的原始资料，存在本地。分三种：
- **Source**：用户在 Quick Add 里粘贴或输入的原文（比如一段微信聊天），每条经过模型整理的 Note 都有一份；
- **File**：用户加入的文件，原样复制一份；
- **Web Page**：用户给的网页链接，保存 URL、抽出的正文和一份 PDF 快照。
_Avoid_: 附件（说 Material；File 只是 Material 的一种）、Attachment、Source（单独说 Source 时只指原文）

**Readable Text**:
从 Material 里抽出、可以交给模型的文字。PDF 和文本文件直接抽取，图片用本地 OCR，Web Page 用正文抽取。其他类型的 File 没有 Readable Text，只存不读。
_Avoid_: 解析结果、内容

### 整理

**Quick Add**:
按 Hotkey 唤起的浮动面板，用来粘贴、拖入、输入内容，生成 Draft 并保存成 Note。
_Avoid_: Quick Panel（那是 Chatbot 的说法）、弹窗、输入框

**Draft**:
模型根据 Quick Add 的输入生成、还没保存的 Note。一次输入可以生成 1–N 条 Draft，用户可以修改、取消勾选，然后一起保存。
_Avoid_: 预览、候选

**Organize**:
把 Quick Add 的输入（原文 + 各 Material 的 Readable Text）交给模型、得到 Draft 的那一次调用。
_Avoid_: 总结、生成、AI 整理（文案里可以用 Organize）

### 界面

**Board**:
固定在桌面上的看板窗口，单列列出所有 Note。
_Avoid_: 主窗口、Main Window、列表页

**Board Mode**:
Board 的窗口层级，二选一：**On Desktop**（桌面层，像 Stickies，被其他窗口盖住，回到桌面时可见）和 **On Top**（始终在最前）。
_Avoid_: 置顶模式、Pinned

**Hotkey**:
唤起 Quick Add 的全局快捷键，默认 option+N，可以改。
_Avoid_: 快捷键（不加限定时容易和面板内的快捷键混淆）

### 模型接入（沿用 Chatbot）

**Connection**:
用户配置的一条模型接入：名称、base URL、API key、Model 列表。v1 只有 OpenAI 兼容协议。
_Avoid_: Provider（v1 只有一种协议，不出现这个词）、账号、Endpoint

**Platform**:
按 Connection 的 base URL host 识别的平台：DeepSeek 官方、OpenRouter、阿里云百炼。决定关闭思考等非标准字段怎么发。

**Model**:
某个 Connection 下的一个模型 ID，例如 `deepseek-flash`。

**Default Model**:
Organize 使用的 Model，设置里指定。
