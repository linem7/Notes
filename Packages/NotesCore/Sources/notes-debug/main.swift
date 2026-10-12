// 调试用的命令行：用真实的 key 跑一次 Organize。Organize 在 ARCHITECTURE §11 第 5 步实现，现在只是占位。
//
// 用法（在 Mac 上，仓库根目录）：
//   swift run --package-path Packages/NotesCore notes-debug

import Foundation
import NotesCore

FileHandle.standardError.write(Data("notes-debug 还没有实现（见 docs/ARCHITECTURE.md §11 第 5 步）。\n".utf8))
exit(1)
