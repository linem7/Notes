#if canImport(Vision) && canImport(CoreText)
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import NotesCore

/// 只在 Apple 平台上跑（CI）：图片和扫描版 PDF 都用 CoreGraphics 现场画出来。
struct ImageOCRTests {
    private func drawText(_ string: String, in context: CGContext, size: CGSize) {
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("Helvetica" as CFString, 72, nil)
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

    /// 一页只有位图、没有文字层的 PDF，模拟扫描版。
    private func scannedPDF(_ string: String) throws -> Data {
        let image = try bitmap(string)
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 700, height: 150)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

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
}
#endif
