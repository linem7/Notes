# MEMORY

## 进度（2026-10-13）
- #2–#11、#33 均已完成并合并；旧的 A/B/C 线排期、待接线与待合并状态已失效。
- #36 / PR #41：垃圾回收列目录失败不再被吞掉；#37 / PR #42：Due Date 非法日期回读校验；#38：OCR 已修复并复核关闭；#39 / PR #43：取消等待测试通过时也记录耗时。
- #1 的 17 条待确认和 2 条 Parked 已逐条复核归档。保留宽松解析、Title 空白归一化、单条坏数据丢弃；术语按 CONTEXT.md 逐键判断。Hotkey 的空 localizations 有意保留；文档继续使用英文源文案定位控件。
- 用户本轮明确确认「真机测试已经通过了」，#1 真机清单依据用户确认归档；不是代理本轮逐项实测。
- 用户确认验收完成后授权清理；已删除 /tmp/nbhang 与 /tmp/notes-doc-snapshots。/tmp/review-build-scratch、/tmp/spec32-scratch 复核时已不存在。~/.claude/settings.json 的两个时间戳备份已删除，原文件保留。
- #45：v1 后补手动界面文案核对脚本，不加入 CI，不阻塞发布；接替已关闭 #11 的维护归属。
- #44 / PR #46：取消等待测试上限 1 → 2 秒，使用 ContinuousClock；本机完整测试连跑 10 次（每次 446 tests / 42 suites）全通过，目标用例 0.118–0.137 秒。改后注入旧忙等 3 次均在约 3.15 秒失败；故障桩已恢复。macos-26 CI（run 38341614328）构建及 446 tests 全通过，目标用例 0.373 秒；PR #46 已合并。

## 环境（2026-10-12 更正，重要）
- **开发这台机器是 macOS 27.0、Xcode 27.0、Swift 6.4、XcodeGen 2.46、arm64。** 可以本地跑
  `swift test --package-path Packages/NotesCore`、`xcodegen generate`、`xcodebuild`，不必只靠 CI。
- 这里原先记的「本机是 Linux，不能构建 macOS app」是**旧机器**的记录，**已作废**，不要再用它当不构建的理由。
- 但 CI runner 仍是 **macos-26 / Xcode 26**，比本机旧：**本地绿不等于 CI 绿**（反向也一样）。两边都要跑，
  PR 描述里如实写清哪边验证过、哪边没有。**绝不声称没做过的验证。**
- 界面和交互的真机核对仍然由用户在 Mac 上做。

## 用户偏好
- 提问用 AskUserQuestion 并给出推荐项；用户不在时按 AGENTS.md 的 L1 / L2 / L3 处理。
- 团队用 team-orchestrator，团队名 `notes`：`dev-lead` 向用户汇报，下设三个部门各 3 个 worker ——
  **frontend**（`App/`）、**backend**（`Packages/NotesCore/`）、**review**（对照 SPEC/ARCHITECTURE 审核、
  独立复跑、文档与发布）。
- PR 由团队自查 + CI 绿后自行合并到 main。**v0.1.0 的 tag 和 GitHub Release 由用户做**，
  打包上传是用户在 Mac 上跑 `scripts/package-release.sh` 之后的事，团队不要碰。
- 一条分支同一时刻只有一个写者；并行用 `git worktree`，放在 `.worktrees/<分支名>/`
  （已加进 `.git/info/exclude`），worker 的 cwd 保持项目根目录，不要 `cd` 出去。
