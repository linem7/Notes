import Foundation
import Testing
@testable import NotesCore

/// 文本类用例在非 Apple 平台也能跑；PDF 和 OCR 靠 `#if canImport(PDFKit)` / Vision 隔着，
/// **任何 Apple 平台都跑**（本机 macOS 和 CI 都跑），不限于 CI。
/// 注意：PDFKit / Vision 的输出随系统版本变，那些用例的断言不能依赖具体词被认对（见 `ImageOCRTests`）。
struct MaterialIntakeTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MaterialIntakeTests-\(UUID().uuidString)", isDirectory: true)

    private func makeIntake(fetcher: (any WebPageFetching)? = nil) throws -> MaterialIntake {
        let files = MaterialFiles(root: root)
        return MaterialIntake(files: files, session: try files.makeStagingSession(), fetcher: fetcher)
    }

    private func source(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let folder = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func source(_ name: String, text: String) throws -> URL {
        try source(name, Array(text.utf8))
    }

    private func readable(_ name: String, _ bytes: [UInt8]) async throws -> ReadableTextState {
        let intake = try makeIntake()
        return await intake.prepare(try intake.stage(fileAt: try source(name, bytes))).state
    }

    // MARK: staging

    @Test func stagingCopiesTheFileAndKeepsTheOriginal() throws {
        let original = try source("a.md", text: "# a")
        let staged = try makeIntake().stage(fileAt: original)
        #expect(staged.kind == .file)
        #expect(staged.displayName == "a.md")
        let copy = try #require(staged.fileURL)
        #expect(copy != original)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "# a")
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func stagingAMissingFileFails() throws {
        let missing = root.appendingPathComponent("nope.txt")
        #expect(throws: MaterialIntakeError.cannotStage(name: "nope.txt")) {
            try makeIntake().stage(fileAt: missing)
        }
    }

    @Test func eachStagedMaterialGetsItsOwnID() throws {
        let intake = try makeIntake()
        let url = try source("a.md", text: "# a")
        #expect(try intake.stage(fileAt: url).id != intake.stage(fileAt: url).id)
    }

    @Test func pastedImagesAreNamedWithTheTime() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let staged = try makeIntake().stage(imageData: Data([1, 2, 3]), now: now)
        #expect(staged.displayName.hasPrefix("Pasted Image 20"))
        #expect(staged.displayName.hasSuffix(".png"))
        #expect(!staged.displayName.contains(":"))
        #expect(try Data(contentsOf: try #require(staged.fileURL)) == Data([1, 2, 3]))
    }

    @Test func stagingALinkTouchesNoDisk() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        let staged = try makeIntake().stage(url: url)
        #expect(staged.kind == .webPage)
        #expect(staged.url == url)
        #expect(staged.fileURL == nil)
    }

    // MARK: 文本和代码

    @Test func sourceFilesAreReadAsText() async throws {
        let state = try await readable("main.swift", Array("print(\"你好\")\n".utf8))
        #expect(state == .ready("print(\"你好\")\n"))
    }

    @Test func unknownExtensionsAreReadWhenTheyAreText() async throws {
        #expect(try await readable("Makefile", Array("all:\n\tswift build\n".utf8)) == .ready("all:\n\tswift build\n"))
    }

    @Test func utf8ByteOrderMarkIsRemoved() async throws {
        #expect(try await readable("a.csv", [0xEF, 0xBB, 0xBF] + Array("a,b".utf8)) == .ready("a,b"))
    }

    @Test func utf16WithByteOrderMarkIsDecoded() async throws {
        var bytes: [UInt8] = [0xFF, 0xFE]
        for unit in "中文 text".utf16 { bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        #expect(try await readable("a.txt", bytes) == .ready("中文 text"))
    }

    @Test(arguments: [false, true])
    func utf32WithByteOrderMarkIsDecoded(bigEndian: Bool) async throws {
        var bytes: [UInt8] = bigEndian ? [0x00, 0x00, 0xFE, 0xFF] : [0xFF, 0xFE, 0x00, 0x00]
        for scalar in "中文 text".unicodeScalars {
            let value = scalar.value
            let le = [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
            bytes += bigEndian ? le.reversed() : le
        }
        #expect(try await readable("a.txt", bytes) == .ready("中文 text"))
    }

    #if canImport(Darwin)
    /// UTF-8 解不开时交给系统的编码检测（ARCHITECTURE §5 的「系统编码检测」，GBK、Shift_JIS 这类旧文件）。
    /// 具体识别成哪个编码由 `NSString.stringEncoding` 决定、会随系统版本变，所以只断言「解出来了、中文没坏」。
    @Test func legacyEncodingsAreDecodedWhenTextIsNotUTF8() async throws {
        // 「这份文件是很久以前用 GBK 编码保存的旧资料。」的 GB18030 字节：没有 NUL，也不是合法 UTF-8
        let bytes: [UInt8] = [
            0xD5, 0xE2, 0xB7, 0xDD, 0xCE, 0xC4, 0xBC, 0xFE, 0xCA, 0xC7, 0xBA, 0xDC, 0xBE, 0xC3,
            0xD2, 0xD4, 0xC7, 0xB0, 0xD3, 0xC3, 0x20, 0x47, 0x42, 0x4B, 0x20, 0xB1, 0xE0, 0xC2,
            0xEB, 0xB1, 0xA3, 0xB4, 0xE6, 0xB5, 0xC4, 0xBE, 0xC9, 0xD7, 0xCA, 0xC1, 0xCF, 0xA1, 0xA3,
        ]
        guard case .ready(let text) = try await readable("旧资料.txt", bytes) else {
            Issue.record("不是 ready"); return
        }
        #expect(text.contains("这份文件"))
        #expect(text.contains("GBK"))
    }
    #endif

    @Test func binaryFilesAreNotReadable() async throws {
        // .docx 是 zip，里面有 NUL 字节
        let state = try await readable("报告.docx", [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x06, 0x00, 0x00, 0x00])
        #expect(state == .unavailable(.notReadable))
    }

    @Test func bundleDirectoriesAreStagedButNotReadable() async throws {
        // .pages、.key 这类文稿在 Finder 里看起来是文件，其实是目录
        let bundle = root.appendingPathComponent("周报.pages", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Data"), withIntermediateDirectories: true)
        let intake = try makeIntake()
        let staged = try intake.stage(fileAt: bundle)
        #expect(staged.displayName == "周报.pages")
        #expect(await intake.prepare(staged).state == .unavailable(.notReadable))
    }

    @Test func aFileThatDisappearsIsUnreadable() async throws {
        let intake = try makeIntake()
        let staged = try intake.stage(fileAt: try source("a.txt", text: "x"))
        try FileManager.default.removeItem(at: try #require(staged.fileURL))
        #expect(await intake.prepare(staged).state == .unavailable(.unreadableFile))
    }

    @Test func hugeTextFilesAreCutAtTheByteLimitOnACharacterBoundary() async throws {
        // "中" 是 3 字节，1_000_000 不是 3 的倍数，截断正好切在字符中间
        let count = TextDecoder.byteLimit / 3 + 100
        let state = try await readable("big.txt", Array(String(repeating: "中", count: count).utf8))
        guard case .ready(let text) = state else { Issue.record("不是 ready"); return }
        #expect(text.count == TextDecoder.byteLimit / 3)
        #expect(text.allSatisfy { $0 == "中" })
    }

    // MARK: 取消

    @Test func cancelledTasksReportCancelled() async throws {
        let intake = try makeIntake()
        let staged = try intake.stage(fileAt: try source("a.txt", text: "x"))
        let task = Task {
            // 睡眠在取消时立刻返回；不用忙等，免得占住协作线程
            try? await Task.sleep(for: .seconds(60))
            return await intake.prepare(staged)
        }
        task.cancel()
        #expect(await task.value.state == .unavailable(.cancelled))
    }

    // MARK: Web Page

    private struct StubFetcher: WebPageFetching {
        var result: Result<WebPageResult, any Error>
        func fetch(_ url: URL) async throws -> WebPageResult { try result.get() }
    }

    private struct Boom: Error {}

    private func webPage(_ result: Result<WebPageResult, any Error>) async throws -> PreparedText {
        let intake = try makeIntake(fetcher: StubFetcher(result: result))
        return await intake.prepare(intake.stage(url: try #require(URL(string: "https://example.com/a"))))
    }

    @Test func webPagesReturnTextTitleAndSnapshot() async throws {
        let prepared = try await webPage(.success(WebPageResult(title: " 标题 ", text: "正文\n", pdfData: Data([9]))))
        #expect(prepared == PreparedText(state: .ready("正文"), title: "标题", snapshotPDF: Data([9])))
    }

    @Test func webPagesWithoutTextAreUnavailableButKeepTheSnapshot() async throws {
        let prepared = try await webPage(.success(WebPageResult(title: "", text: "  \n", pdfData: Data([9]))))
        #expect(prepared.state == .unavailable(.pageHasNoText))
        #expect(prepared.title == nil)
        #expect(prepared.snapshotPDF == Data([9]))
    }

    @Test func anEmptyPageKeepsItsTitleAndSnapshot() async throws {
        // WebPageFetcher 在 Readability 和 innerText 都为空时返回 text: ""，而不是抛错
        let prepared = try await webPage(.success(WebPageResult(title: " Sign in ", text: "", pdfData: Data([9]))))
        #expect(prepared == PreparedText(state: .unavailable(.pageHasNoText), title: "Sign in", snapshotPDF: Data([9])))
    }

    @Test func failedFetchesAreUnavailable() async throws {
        #expect(try await webPage(.failure(Boom())).state == .unavailable(.pageLoadFailed))
        #expect(try await webPage(.failure(CancellationError())).state == .unavailable(.cancelled))
        for error in [WebFetchError.loadFailed, .timedOut, .invalidURL] {
            #expect(try await webPage(.failure(error)).state == .unavailable(.pageLoadFailed))
        }
    }

    @Test func webPagesWithoutAFetcherAreUnavailable() async throws {
        let intake = try makeIntake()
        let staged = intake.stage(url: try #require(URL(string: "https://example.com")))
        #expect(await intake.prepare(staged).state == .unavailable(.pageLoadFailed))
    }
}

#if canImport(PDFKit)
/// 靠 `#if canImport(PDFKit)` 隔着：**任何 Apple 平台都跑**（本机 macOS 和 CI 都跑），不限于 CI。
/// Fixtures/text.pdf 和 Fixtures/scanned.pdf 是手写的最小 PDF：
/// 前者有一行文字 "Hello PDF"，后者是一个空白页，模拟扫描版。
@Suite(.timeLimit(.minutes(1)))
struct PDFIntakeTests {
    private func fixtureURL(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    @Test func textIsExtractedLocally() throws {
        let text = try PDFTextExtractor.text(from: try fixtureURL("text.pdf"))
        #expect(try #require(text).contains("Hello PDF"))
    }

    @Test func pdfsWithoutTextReturnNilRatherThanThrowing() throws {
        #expect(try PDFTextExtractor.text(from: try fixtureURL("scanned.pdf")) == nil)
    }

    @Test func brokenPDFsThrow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID().uuidString).pdf")
        try Data([1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: PDFTextError.unreadable) { try PDFTextExtractor.text(from: url) }
    }

    @Test func textPDFsBecomeReady() async throws {
        let files = MaterialFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let intake = MaterialIntake(files: files, session: try files.makeStagingSession())
        let staged = try intake.stage(fileAt: try fixtureURL("text.pdf"))
        guard case .ready(let text) = await intake.prepare(staged).state else { Issue.record("不是 ready"); return }
        #expect(text.contains("Hello PDF"))
    }
}
#endif
