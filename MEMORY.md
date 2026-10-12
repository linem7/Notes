# MEMORY

## 进度
- 2026-10-12：grilling 完成，SPEC / ARCHITECTURE / CONTEXT / ADR 落地；按 ARCHITECTURE §11 拆 issue。
- 2026-10-12：#2–#8 已合并（工程骨架、NotesCore 存储 / 客户端 / Intake / Organize、WebPageFetcher、Board）。
- 2026-10-12：剩下的三个 issue 交给 team-orchestrator 的 `notes` 团队收尾：
  - **#9 Quick Add** —— PR #22，Draft，CI 红（`Test NotesCore` 挂住直到 15 分钟超时）。
  - **#10 菜单栏、设置、首次启动、界面语言、开机启动** —— PR #23，CI 绿，等 #9 合并后接 Quick Add。
  - **#11 测试补齐、INSTALL.md、v0.1.0 发布准备** —— PR #13，Draft，只含文档部分。
- 2026-10-12：团队暂停后恢复；三层结构生效——dev-lead 只管跨部门排序 / 合并 / 维护 #1 / 汇报，frontend / backend / review 三个部门 lead 各自计划、分派、审本部门。
- 2026-10-12：B 线、C 线改走 `git merge origin/main`，不再 rebase——rebase 已推送过的分支会产生 non-fast-forward，只能 force push，而它是 deny。C 线改为「从远端建 `issue-13-publish` 分支 + merge + fast-forward push」。
- 2026-10-12：SPEC §2.2（数据库打不开时 Board 内纠错态 + Quick Add 禁止保存）用户定为纳入 v1，另开 issue #33，排在 #9 合并之后。

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
