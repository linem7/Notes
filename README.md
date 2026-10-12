# Notes

A macOS desktop task-note app. Pin the board to your desktop, or press **Option + N** anywhere: paste a WhatsApp/WeChat chat, drop a file, paste a link or just type, and a fast LLM (DeepSeek by default, thinking off) turns it into a short, clear note: **title + due date + detail**. Original files, web pages and the pasted text are kept locally so you can open them while doing the task.

- 一个固定在桌面的任务便签。按 **Option + N** 唤起，粘贴聊天记录、拖入文件、贴链接或直接输入，模型整理成「标题 + 截止日期 + 要点」的 Note；原始文件、网页快照和原文保存在本地，执行任务时一键打开。

**Status:** v1 in development. See [docs/SPEC.md](docs/SPEC.md) (spec), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (implementation), [CONTEXT.md](CONTEXT.md) (glossary), [docs/adr/](docs/adr/) (decisions).

Requirements: macOS 26+, Apple Silicon, your own API key (DeepSeek or any OpenAI-compatible service).

Build instructions will be added with the project skeleton (same flow as [linem7/Chatbot](https://github.com/linem7/Chatbot): XcodeGen + a fixed self-signed certificate `Notes Self-Signed`).
