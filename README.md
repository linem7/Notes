# Notes

A macOS desktop task-note app. Pin the board to your desktop, or press **Option + N** anywhere: paste a WhatsApp/WeChat chat, drop a file, paste a link or just type, and a fast LLM (DeepSeek by default, thinking off) turns it into a short, clear note: **title + due date + detail**. Original files, web pages and the pasted text are kept locally so you can open them while doing the task.

- 一个固定在桌面的任务便签。按 **Option + N** 唤起，粘贴聊天记录、拖入文件、贴链接或直接输入，模型整理成「标题 + 截止日期 + 要点」的 Note；原始文件、网页快照和原文保存在本地，执行任务时一键打开。

## 下载与安装

**v0.1.0（开发中，尚未发布）：macOS 26 或以上，Apple Silicon（M 系列芯片）。**

[下载安装包](https://github.com/linem7/Notes/releases)（TODO：v0.1.0 发布后换成直链） · [完整安装指引](docs/INSTALL.md) · [所有版本](https://github.com/linem7/Notes/releases)

解压后把 `Notes.app` 拖进 **Applications**。首次打开如被拦截，进入 **System Settings › Privacy & Security › Open Anyway**。应用采用自签名、未经过 Apple 公证；使用时需要自己的 API key。无需安装 Xcode 或创建证书。

## 功能

完整规格见 [docs/SPEC.md](docs/SPEC.md)。

- **Board**：固定在桌面上的单列看板，按 Overdue / Today / Upcoming / No Date / Done 分组；On Desktop（像 Stickies 钉在桌面）或 On Top（始终在最前）。
- **Quick Add**：按 **Option + N**（可改）从任何 app 唤起，粘贴聊天记录、拖入文件、贴链接或直接输入。
- **Organize**：模型（默认 DeepSeek，不开思考）整理成 **标题 + 截止日期 + 要点**，一次输入可拆成多条，保存前可逐条修改；⌘⏎ 可跳过模型原样保存。
- **Material**：原文、文件、网页（正文 + PDF 快照）保存在本地，执行任务时一键打开；PDF、图片（本地 OCR）、文本和网页可被模型读取。
- 常驻菜单栏，图标旁显示今天到期和已逾期的数量；不发通知、不做提醒、不同步，数据都在本机。

**不做**：系统通知和日历、模型思考和联网搜索、读取 Word / Excel / PPT、搜索和标签、iCloud 同步、自动更新（详见 SPEC §10）。

**Status:** v1 in development (project skeleton: menu bar icon + Quit only). See [docs/SPEC.md](docs/SPEC.md) (spec), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) (implementation), [CONTEXT.md](CONTEXT.md) (glossary), [docs/adr/](docs/adr/) (decisions).

Requirements: macOS 26+, Apple Silicon, your own API key (DeepSeek or any OpenAI-compatible service).

## 从源码构建和安装

用 XcodeGen 生成工程，app 用固定的自签名证书 `Notes Self-Signed` 签名，没有经过 Apple 公证（[ADR-0004](docs/adr/0004-self-signed-certificate-no-notarization.md)）。

### 准备

- macOS 26 和 Xcode 26
- XcodeGen：`brew install xcodegen`

### 创建自签名证书（只需做一次）

API key 存在 Keychain 里，Keychain 按签名身份判断访问权限。所以每次构建都要用**同一张**证书签名，否则重新构建后读 key 时会反复弹窗。

1. 打开 **Keychain Access**。从 macOS 15 起，它不在 Applications › Utilities 里了，在 Terminal 里执行：

   ```sh
   open -a "Keychain Access"
   ```

   如果提示找不到，用完整路径：

   ```sh
   open "/System/Library/CoreServices/Applications/Keychain Access.app"
   ```

2. 在**屏幕顶部的菜单栏**（不是窗口里）点 **Keychain Access** 菜单，选 **Certificate Assistant › Create a Certificate…**。
3. 在弹出的窗口里：
   - **Name** 填 `Notes Self-Signed`（必须和 `project.yml` 里的 `CODE_SIGN_IDENTITY` 一致）；
   - **Identity Type** 选 **Self-Signed Root**；
   - **Certificate Type** 选 **Code Signing**；
   - 勾选 **Let me override defaults**，点 **Continue**。
4. **Validity Period (days)** 填 `7300`（20 年），之后的页面一路点 **Continue** 保持默认；问到存在哪个 keychain 时选 **login**，最后点 **Create**。
5. 回到 Keychain Access 窗口，在左侧选 **login** keychain，在 **My Certificates**（或 **Certificates**）里双击 `Notes Self-Signed`。展开 **Trust**，把 **Code Signing** 设为 **Always Trust**，关闭窗口，输入登录密码确认。
6. 在 Terminal 里确认它能用于签名：

   ```sh
   security find-identity -v -p codesigning
   ```

   输出里应该有一行 `"Notes Self-Signed"`。
7. **备份**：在 Keychain Access 里右键这张证书 → **Export "Notes Self-Signed"…**，格式选 **Personal Information Exchange (.p12)**，设一个密码，存到安全的地方。私钥丢了就只能换证书，换证书后第一次读 key 会再弹一次 Keychain 授权。

### 构建和安装

在仓库里运行：

```sh
./scripts/install.sh
```

脚本会依次：检查 Xcode、XcodeGen 和签名证书 → 生成工程 → 构建 Release → 退出正在运行的 Notes → 删掉旧的 `/Applications/Notes.app` 并装上新的 → 校验签名 → 启动。任何一步失败都会停下来，并说明原因。第一次构建要下载依赖，会慢一些。

装好之后，Notes 平时只出现在菜单栏，不占 Dock。工程骨架阶段的 app 只有菜单栏图标和 **Quit Notes**，其余功能按 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) §11 逐步加入。

本机构建的 app 没有隔离标记（quarantine），不会被 Gatekeeper 拦下。从 GitHub Release 下载的 app 首次打开如被拦截，需要到 **System Settings › Privacy & Security** 里点 **Open Anyway**（ADR-0004）。

手动构建的步骤（和脚本做的事一样）：

```sh
xcodegen generate                    # 由 project.yml 生成 Notes.xcodeproj
xcodebuild -project Notes.xcodeproj -scheme Notes -configuration Release \
  -derivedDataPath build build
rm -rf /Applications/Notes.app      # 先删掉旧版本，避免旧 bundle 里多出的文件让签名失效
ditto build/Build/Products/Release/Notes.app /Applications/Notes.app
```

也可以 `open Notes.xcodeproj` 后在 Xcode 里构建运行。改了 `project.yml` 或增删了源文件后，要重新执行 `xcodegen generate`。

### 源码安装的升级

拉取最新代码后，再运行一次 `./scripts/install.sh`。证书没变，所以 Keychain 不会再要求授权。如果还是弹了，选 **Always Allow**，之后就不会再弹。设置、数据和 key 都会保留。

### 卸载

如果开启过 **Launch at Login**，先在 Settings 里关掉；然后从菜单栏图标的菜单里选 **Quit Notes**，再执行：

```sh
rm -rf /Applications/Notes.app
rm -rf ~/Library/Application\ Support/com.linem7.Notes     # Note 和 Material
defaults delete com.linem7.Notes                            # 设置
rm -rf ~/Library/Caches/com.linem7.Notes                    # 缓存
rm -rf ~/Library/HTTPStorages/com.linem7.Notes              # 网络请求的存储
# Keychain 里的 API key：每个 Connection 一条，删到没有为止
while security delete-generic-password -s com.linem7.Notes.apikey >/dev/null 2>&1; do :; done
```

自签名证书如果不再需要，可以在 Keychain Access 里删掉。

### 常见问题

- **构建时报找不到签名身份 `Notes Self-Signed`**：证书没有建好，或者 **Code Signing** 没有设成 **Always Trust**。按上面「创建自签名证书」检查，`security find-identity -v -p codesigning` 里要能看到它。
- **每次重新安装后，Keychain 都要求授权**：说明签名身份变了，例如重建了证书，或者没用脚本、而是用 Xcode 的 **Sign to Run Locally** 构建的。在弹窗里选 **Always Allow** 一次即可；以后一直用同一张证书构建。
- **按 option+N 没反应**（Hotkey 功能实现后）：可能和别的 app 的快捷键冲突，在 Settings 里换一个 **Hotkey**。
- **运行脚本时弹出 "Terminal" wants access to control "Notes"**：这是 macOS 的 Automation 授权，脚本要用它退出正在运行的旧版本。点 **Allow** 即可。如果点了 **Don't Allow**，脚本会停下来，提示你从菜单栏手动退出 Notes，退出后再运行一次就行；以后想改，可以到 **System Settings › Privacy & Security › Automation** 里调整。

只跑核心逻辑（NotesCore）的测试：

```sh
swift test --package-path Packages/NotesCore
```

CI（`.github/workflows/ci.yml`，macos-26）在 push 到 main 和 PR 时执行同样的生成、构建和测试，但不签名。

### 制作 Release 安装包

在配置好上述构建环境和固定签名证书的 Mac 上执行：

```sh
./scripts/package-release.sh
```

脚本只构建 Apple Silicon Release 并打包到 `build/releases/`，不会安装或启动应用，也不运行测试。生成 ZIP 和 SHA-256 校验文件，可上传到对应版本的 GitHub Release。
