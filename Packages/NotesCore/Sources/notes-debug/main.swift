// 调试用的命令行：用真实的 key 跑一次 Organize，打印得到的 Draft。
//
// 用法（在 Mac 上，仓库根目录）：
//   NOTES_API_KEY=sk-... swift run --package-path Packages/NotesCore notes-debug input.txt
//
// 环境变量：
//   NOTES_API_KEY   必填
//   NOTES_BASE_URL  默认 https://api.deepseek.com
//   NOTES_MODEL     默认 deepseek-flash
//
// 材料路径（文件）等 MaterialIntake（#5）合并后再加。

import Foundation
import NotesCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let environment = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 else { fail("usage: notes-debug <input-text-file>") }
guard let apiKey = environment["NOTES_API_KEY"], !apiKey.isEmpty else { fail("NOTES_API_KEY is not set") }
guard let input = try? String(contentsOfFile: arguments[0], encoding: .utf8) else { fail("can't read \(arguments[0])") }

let baseURLString = environment["NOTES_BASE_URL"] ?? "https://api.deepseek.com"
guard let baseURL = URL(string: baseURLString), baseURL.scheme != nil, baseURL.host != nil else {
    fail("NOTES_BASE_URL is not a valid URL: \(baseURLString)")
}
let modelID = environment["NOTES_MODEL"] ?? "deepseek-flash"
let connection = Connection(name: "debug", baseURL: baseURL)

do {
    let started = Date()
    let drafts = try await Organizer().organize(
        input: input, promptMaterials: [], connection: connection, modelID: modelID, apiKey: apiKey
    )
    print("\(drafts.count) draft(s) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s\n")
    for (offset, draft) in drafts.enumerated() {
        let due = draft.due.map { "\($0.day)\($0.time.map { " \($0)" } ?? "")" } ?? "-"
        print("[\(offset + 1)] \(draft.title)\n    due: \(due)\n    materials: \(draft.materialIndices)\n    detail:\n\(draft.detail)\n")
    }
} catch let error as ChatError {
    fail("model call failed: \(error)")
} catch {
    fail("\(error)")
}
