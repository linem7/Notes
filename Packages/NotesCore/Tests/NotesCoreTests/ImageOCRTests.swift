#if canImport(Vision) && canImport(CoreText)
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NotesCore

/// 靠 `#if canImport(Vision)` 隔着：**任何 Apple 平台都跑**（本机 macOS 和 CI macos-26 都跑），不限于 CI。
/// 图片和扫描版 PDF 都用 CoreGraphics 现场画出来。
///
/// **Vision 的输出随系统版本变，别假设两边一致**：同一张渲染出来的 `"Alpha report"`，本机 macOS 27
/// 认成 `"Alpn"`、CI macos-26 认成 `"Alpha"`。这类用例的断言不能依赖某个词被认对
/// （`onlyTheFirstPagesOfAScannedPDFAreRecognized` 用「设上限 / 不设上限」两次结果对照就是因为这个）。
///
/// 串行 + 时限：Vision 在 CI 虚拟机上卡住时，只让一个测试占住线程，并且 1 分钟后明确失败，不拖死整个任务。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ImageOCRTests {
    private func drawText(_ string: String, in context: CGContext, size: CGSize, fontSize: CGFloat = 72) {
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.textPosition = CGPoint(x: 40, y: size.height / 2 - 20)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    private func bitmap(_ string: String) throws -> CGImage {
        let size = CGSize(width: 1_400, height: 300)
        let context = try #require(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        drawText(string, in: context, size: size)
        return try #require(context.makeImage())
    }

    private func pngData(_ string: String) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try bitmap(string), nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    enum PageContent {
        /// 只有位图、没有文字层，模拟扫描版
        case bitmap(String)
        /// 有文字层的页
        case text(String)
    }

    private func pdf(_ pages: [PageContent]) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 700, height: 150)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case .bitmap(let string):
                context.draw(try bitmap(string), in: box)
            case .text(let string):
                drawText(string, in: context, size: box.size, fontSize: 30)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func scannedPDF(_ string: String) throws -> Data { try pdf([.bitmap(string)]) }

    private func normalized(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }

    private func prepared(named name: String, _ data: Data) async throws -> ReadableTextState {
        let files = MaterialFiles(root: FileManager.default.temporaryDirectory.appendingPathComponent("OCR-\(UUID().uuidString)"))
        let intake = MaterialIntake(files: files, session: try files.makeStagingSession())
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        return await intake.prepare(try intake.stage(fileAt: source)).state
    }

    @Test func imagesWithEnglishTextAreRecognized() async throws {
        let state = try await prepared(named: "shot.png", try pngData("Send the contract 2026"))
        guard case .ready(let text) = state else { Issue.record("OCR 没有结果：\(state)"); return }
        #expect(normalized(text).contains("contract"))
    }

    @Test func imagesWithChineseTextAreRecognized() async throws {
        let state = try await prepared(named: "聊天.png", try pngData("明天下午交合同"))
        guard case .ready(let text) = state else { Issue.record("OCR 没有结果：\(state)"); return }
        #expect(text.contains("合同"))
    }

    @Test func blankImagesHaveNoRecognizedText() async throws {
        let state = try await prepared(named: "blank.png", try pngData(""))
        #expect(state == .unavailable(.noTextRecognized))
    }

    @Test func brokenImagesAreUnreadable() async throws {
        let state = try await prepared(named: "坏的.png", Data([1, 2, 3]))
        #expect(state == .unavailable(.unreadableFile))
    }

    @Test func scannedPDFsFallBackToOCR() async throws {
        let state = try await prepared(named: "scan.pdf", try scannedPDF("Quarterly report"))
        guard case .ready(let text) = state else { Issue.record("OCR 没有结果：\(state)"); return }
        #expect(normalized(text).contains("report"))
    }

    @Test func blankScannedPDFsHaveNoRecognizedText() async throws {
        let url = try #require(Bundle.module.url(forResource: "scanned.pdf", withExtension: nil, subdirectory: "Fixtures"))
        let state = try await prepared(named: "scanned.pdf", try Data(contentsOf: url))
        #expect(state == .unavailable(.noTextRecognized))
    }

    @Test func onlyTheFirstPagesOfAScannedPDFAreRecognized() throws {
        let data = try pdf([.bitmap("Alpha report"), .bitmap("Bravo report"), .bitmap("Charlie report")])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString).pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // 词认成什么样随 Vision 版本变（本机 macOS 27 把 "Alpha" 认成 "Alpn"、"Charlie" 认成 "Chalre"），
        // 所以「前两页出了字、第三页没出」用两次结果对照说明，不靠某个词被拼对：
        // 三页各有一处 "report"，数它就等于数 OCR 到了几页。
        func pagesRead(_ text: String) -> Int { text.components(separatedBy: "report").count - 1 }
        let capped = normalized(try ImageOCR.recognizeText(inPDFAt: url, maxPages: 2))
        let everything = normalized(try ImageOCR.recognizeText(inPDFAt: url, maxPages: ImageOCR.maxPDFPages))

        #expect(pagesRead(capped) == 2)      // 前 2 页都 OCR 出了字
        #expect(pagesRead(everything) == 3)  // 反证：不设上限时第 3 页也读得出来，差的就是这个 cap
        #expect(!capped.contains("charlie")) // 第 3 页的词没混进来
        #expect(ImageOCR.maxPDFPages == 30)
    }

    @Test func aPDFWithOneTextPageIsReadWithoutOCR() async throws {
        // 第 1 页有文字层，第 2 页是位图：只要有文字就不 OCR，所以位图页上的字不会出现
        let state = try await prepared(named: "mixed.pdf", try pdf([.text("Native text layer"), .bitmap("Hidden scanned words")]))
        guard case .ready(let text) = state else { Issue.record("没有结果：\(state)"); return }
        #expect(normalized(text).contains("native"))
        #expect(!normalized(text).contains("hidden"))
    }
}
#endif
