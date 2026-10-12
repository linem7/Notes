# Notes

macOS 桌面任务便签，原生 Swift + SwiftUI。功能以 `docs/SPEC.md` 为准，实现方案以 `docs/ARCHITECTURE.md` 为准，术语以 `CONTEXT.md` 为准。参考项目 [linem7/Chatbot](https://github.com/linem7/Chatbot)：很多代码从那里移植，移植时连测试一起带过来。

## 任务从哪来

所有工作由 GitHub issue 驱动（`linem7/Notes`，公开仓库）。总览在 tracking issue（label `tracking`）。开工前先读 issue，以及它引用的 SPEC 和 ARCHITECTURE 章节。

## 分支和合并

- 每个 issue 一个分支 `issue-<号>-<短名>`，开 PR 关联 issue（`Closes #<号>`）。
- CI（macos-26）必须通过才能合并。Linux 环境不能构建 macOS app，**不要声称在本机构建或运行过**；如实写明哪些靠 CI 验证、哪些需要真机核实。
- 需要真机核实的点，在 PR 描述里列成 checklist，合并后汇总到 tracking issue 的「真机待验」。

## 遇到要决定的事

- **L1**（小、可逆：文案、间距、实现细节）：直接决定，写在 PR 描述里。
- **L2**（影响体验但容易改）：按推荐做，继续推进，同时在 tracking issue 的「待确认」里加一行。
- **L3**（难以推翻：数据模型、产品范围、成本、分发）：停下来，在 tracking issue 的「Parked」里写清问题和推荐，先做不依赖它的部分。

## 记忆

`MEMORY.md` 记录跨会话要记住的进度和偏好。每次会话开始先读，有新进度就更新，过时就删。

## 约定

- 文档、issue、PR 描述用中文，代码标识符和界面文案（源语言）用英文；界面中文在 `Localizable.xcstrings` 的 zh-Hans 里。
- 术语用 `CONTEXT.md` 里的词，避开 _Avoid_ 下列出的说法。
- 改动数据模型、模型调用参数之前先读 `docs/adr/`。
- 产品取向：快、简单。Note 只有 Title + Due Date + Detail；不开思考、不联网搜索。
