# Notes 安装指引

> **草稿**：随 v0.1.0 打包前定稿。功能描述以 [SPEC](SPEC.md) 为准；标 `TODO` 的地方要等对应 issue 落地、真机核实后补全。
>
> 合并状态（2026-10-12，基线 `main` `7237a8b`）：Board 和 NotesCore 已在 `main`；本文写到的 Quick Add（#9，PR #22）、菜单栏 / 设置 / 首次启动 / 界面语言（#10，PR #23）还没合并，它们的界面文案和位置以合并后的代码为准。文中每处界面名称都能在 SPEC、ARCHITECTURE 或代码里找到来源；只在真机上才能确认的另标 `TODO`。

## 系统要求

- macOS 26 或以上。
- Apple Silicon Mac（M 系列芯片）；安装包不支持 Intel Mac。
- 自己的模型服务 API key（默认 DeepSeek，也可用 OpenRouter、阿里云百炼或任何 OpenAI 兼容服务），以及可用额度和网络连接。应用不附带 API key，模型调用费用由服务商收取。

在 **Apple menu › About This Mac** 查看系统版本和芯片。以下菜单名使用英文；界面语言默认英文，可在设置里改成简体中文。

## 下载和安装

1. 打开 [v0.1.0 Release](https://github.com/linem7/Notes/releases/tag/v0.1.0)，在 **Assets** 下载 `Notes-0.1.0-macOS-arm64.zip`。**Source code** 是开发者用的源码，不是安装包。
2. 双击 ZIP 解压，将 `Notes.app` 拖进 **Applications**。
3. 从 **Applications** 打开 Notes。
4. 应用使用自签名证书，没有经过 Apple 公证。如果首次打开提示 Apple 无法验证开发者或检查应用，在确认文件来自上述 Release 后，进入 **System Settings › Privacy & Security**，向下滚动，点击 **Open Anyway**，然后按提示确认 **Open**。需要先尝试打开一次，系统才会显示该入口。详见 [Apple 的打开说明](https://support.apple.com/en-us/102445)。

无需安装 Xcode、运行终端命令或导入开发者的签名证书。

## 第一次使用

1. 首次启动会打开 **Settings › Connection**，预选 DeepSeek 模板。填入自己的 API key，点 **Save**，应用会拉取模型列表（同时也是连接测试）。拉取失败时可以手填模型 ID。
2. 使用其他服务时，点击 Connection 页的 **+**，选择 OpenRouter、Alibaba Cloud Model Studio，或可填写 base URL 的 **Custom**。只支持 OpenAI 兼容协议。
3. 在 **Settings › Connection › Default Model** 选择 Organize 使用的模型（默认 `deepseek-flash`）。
4. 桌面右侧会出现 **Board**（默认 On Desktop，像 Stickies 钉在桌面上，回到桌面时可见）。按 **Option + N** 唤起 **Quick Add**：粘贴聊天记录、拖入文件、贴链接，或直接打一句话，按 **⏎** 让模型整理成 Note（标题 + 截止日期 + 要点），检查后按 **⌘⏎** 保存。
5. 还没配置 Connection 也能用：不按 ⏎，直接按 **⌘⏎** 会把输入原样保存成一条 Note。

Notes 平时在菜单栏里，不出现在 Dock 和 ⌘Tab；只有打开 Settings 时才临时出现。菜单栏图标旁的数字是今天到期和已逾期的未完成 Note 数量。首次启动默认开启 **Launch at Login**，可在 **Settings › General** 关闭；开启时系统可能显示 **Background Items Added** 通知，这是 macOS 对登录项的处理（TODO：真机核实文案）。

Notes 不发系统通知、不接日历、不做提醒。

## 快捷键和权限

| 位置 | 按键 | 作用 |
|---|---|---|
| 全局 | Option + N（可改） | 唤起 / 隐藏 Quick Add |
| Quick Add | ⏎ | Organize（输入法组字时不触发） |
| Quick Add | ⇧⏎ | 换行 |
| Quick Add | ⌘⏎ | 保存 Draft；没有 Draft 时原样保存输入 |
| Quick Add | ⌘. | 取消 Organize |
| Quick Add | Esc | 隐藏面板（Organize 进行中时先取消） |
| Board（Note 编辑） | ⌘⏎ / Esc | 保存 / 放弃修改；点 Board 别处或切到别的 app（失焦）也会保存 |
| Board（点击选中 Note，未在编辑文字） | ⌫ | 删除 Note，不弹确认；只是展开不算选中，编辑文字时 ⌫ 只删字 |
| 菜单栏菜单打开时 | ⌘, | 打开 Settings。这个组合挂在菜单栏菜单的 **Settings…** 项上，Notes 平时不在前台，菜单没打开时不起作用（TODO：真机核实） |

- 默认 **Option + N** 不需要 Accessibility 或 Screen Recording 权限。在美式键盘上 option+N 原本用来输入 ñ，注册后这个组合不再打字；如果和其他应用冲突，在 **Settings › General › Hotkey** 换一个组合。启动和改键时会检测与系统快捷键的冲突。
- TODO（#7 / #10 落地后核实）：各项权限提示，例如网页抓取、OCR 是否会触发任何系统授权弹窗；目前 SPEC 预期无需额外权限。

## 数据保存在哪里

全部在本机：`~/Library/Application Support/com.linem7.Notes/`

- `notes.sqlite`：Note 和 Material 的记录；
- `materials/files/`：加入的文件副本、网页正文和 PDF 快照、粘贴的原文。同一个文件挂到多条 Note 时只存一份，最后一条用到它的 Note 删除后才删文件。

可在 **Settings › Advanced** 的 **Data Folder** 行点 **Show in Finder**，在 Finder 里显示这个目录。完成超过 30 天的 Note 连同 Material 会静默自动删除。不做 iCloud 同步，也不做导出导入。

聊天记录、文件、网页内容中的文字会发送给你配置的模型服务做 Organize；原始文件本身不会上传（图片 / 扫描版 PDF 在本机用 Apple Vision 做 OCR，只发送识别出的文字）。

## 升级

应用不自动检查更新。到 [Releases](https://github.com/linem7/Notes/releases) 下载新版本，先从菜单栏选择 **Quit Notes**，再将解压后的 `Notes.app` 拖进 **Applications**，按 Finder 提示替换旧版本，然后重新打开。

替换应用会保留设置、API key 和本地 Note，不要执行清理用户数据的卸载命令。API key 存在 macOS Keychain 中（service `com.linem7.Notes.apikey`，与 Chatbot 互不共用）；如果从自行编译版切换到 Release 后出现 Keychain 授权，确认是 Notes 后允许访问。

## 卸载

在 **Settings › General** 关闭 **Launch at Login**，从菜单栏选择 **Quit Notes**，然后将 **Applications** 中的 `Notes.app` 移到废纸篓。这样会保留本地数据，方便重新安装。

如需连同 Note、设置和 Keychain 中的 API key 一起删除，在退出 Notes 后执行（**会永久删除全部 Note 和 Material**）：

```sh
rm -rf /Applications/Notes.app
rm -rf ~/Library/Application\ Support/com.linem7.Notes     # Note 和 Material
defaults delete com.linem7.Notes                            # 设置
rm -rf ~/Library/Caches/com.linem7.Notes                    # 缓存
rm -rf ~/Library/HTTPStorages/com.linem7.Notes              # 网络请求的存储
# Keychain 里的 API key：每个 Connection 一条，删到没有为止
while security delete-generic-password -s com.linem7.Notes.apikey >/dev/null 2>&1; do :; done
```

自签名证书只在自己编译时用到，下载安装包的用户不需要处理。

从源码构建的用户见 [README 的卸载步骤](../README.md#卸载)，命令与上面一致。

## 常见问题

- **打开后看不到窗口**：Notes 在菜单栏里。点菜单栏图标选 **Show Board**，或按 **Option + N**。
- **Board 被别的窗口盖住了**：On Desktop 模式下 Board 像 Stickies 一样钉在桌面层，会被其他窗口盖住；回到桌面可见。想始终在最前，在菜单栏 **Board Mode** 选 **On Top**。
- **Board 关掉后找不到**：关闭按钮只是隐藏，菜单栏选 **Show Board**。
- **Option + N 没反应**：检查是否与其他应用冲突，在 **Settings › General › Hotkey** 换一个组合。
- **按 ⏎ 提示先添加 Connection**：还没配置模型服务。去 **Settings › Connection** 添加，或用 ⌘⏎ 原样保存。
- **模型列表加载失败或 Organize 报错**：检查服务商、API key、额度、网络和 Custom 的 base URL。API 的 key 与网页聊天账户订阅不是同一项配置。错误会显示在 Draft 区，并给出「重试」或「打开设置」。
- **Due Date 不对或没读出来**：Organize 读不出截止日期时会留空而不是编一个；Draft 和 Note 里都可以手动改。
- **文件 / 网页 Material 上有警告标记**：悬停查看原因（抓不到网页、OCR 没有文字等）。警告不阻止 Organize；Word、Excel、PPT 等类型只存不读，模型只看到文件名。
- **改了界面语言没变化**：切换语言后需要重启，点 **Relaunch**。Note 的语言跟随输入，与界面语言无关。
- **系统不显示 Open Anyway**：先从 Applications 尝试打开一次，再查看 Privacy & Security；受组织管理的 Mac 可能限制此操作，需要联系管理员。
- **Board 顶部出现红色「Couldn't save」**：数据库写入失败，修改已回到之前的值，几秒后提示自动消失。请重试；反复出现请到 Issues 反馈（附系统版本，磁盘空间是否充足）。
- **遇到其他问题**：到 [GitHub Issues](https://github.com/linem7/Notes/issues) 描述 macOS 版本、应用版本和复现步骤。截图或错误信息中请隐去 API key 和 Note 中的隐私内容。
