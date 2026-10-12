// 调试用的命令行：用真实的 key 跑一次 Organize，打印得到的 Draft。
//
// 用法（在 Mac 上，仓库根目录）：
//   NOTES_API_KEY=sk-... swift run --package-path Packages/NotesCore notes-debug input.txt [material ...]
//
// input.txt 之后的参数是 Material：文件路径（走和 app 一样的 MaterialIntake：PDF、文本、图片 OCR），
// 或者 http/https 链接（这里没有网页抓取器，链接只会以「读不到」的 Material 交给模型）。
// 不想要文字输入时，input.txt 传空文件。
//
// 环境变量：
//   NOTES_API_KEY   必填
//   NOTES_BASE_URL  默认 https://api.deepseek.com
//   NOTES_MODEL     默认 deepseek-flash
//
import Foundation
import NotesCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// 只打印状态名和字数，不把 Readable Text 全文打到终端里。
func describe(_ state: ReadableTextState) -> String {
    switch state {
    case .pending: "pending"
    case .ready(let text): "ready (\(text.count) characters)"
    case .unavailable(let reason): "unavailable (\(reason))"
    }
}

let environment = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else { fail("usage: notes-debug <input-text-file> [material-file-or-url ...]") }
guard let apiKey = environment["NOTES_API_KEY"], !apiKey.isEmpty else { fail("NOTES_API_KEY is not set") }
guard let input = try? String(contentsOfFile: arguments[0], encoding: .utf8) else { fail("can't read \(arguments[0])") }

let baseURLString = environment["NOTES_BASE_URL"] ?? "https://api.deepseek.com"
guard let baseURL = URL(string: baseURLString), baseURL.scheme != nil, baseURL.host != nil else {
    fail("NOTES_BASE_URL is not a valid URL: \(baseURLString)")
}
let modelID = environment["NOTES_MODEL"] ?? "deepseek-flash"
let connection = Connection(name: "debug", baseURL: baseURL)

do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-debug-\(UUID().uuidString)")
    let files = MaterialFiles(root: root)
    let session = try files.makeStagingSession()
    defer { try? FileManager.default.removeItem(at: root) }
    let intake = MaterialIntake(files: files, session: session)

    var materials: [OrganizeMaterial] = []
    for argument in arguments.dropFirst() {
        let staged: StagedMaterial
        if let url = URL(string: argument), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            staged = intake.stage(url: url)
        } else {
            staged = try intake.stage(fileAt: URL(fileURLWithPath: argument))
        }
        let prepared = await intake.prepare(staged)
        print("material \(materials.count + 1): \(staged.displayName) -> \(describe(prepared.state))")
        materials.append(OrganizeMaterial(staged: staged, prepared: prepared))
    }

    let started = Date()
    let drafts = try await Organizer().organize(
        input: input, materials: materials, connection: connection, modelID: modelID, apiKey: apiKey
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
