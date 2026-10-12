import Foundation

#if canImport(Vision)
import CoreGraphics
import Vision
#if canImport(PDFKit)
import PDFKit
#endif

/// 本地 OCR（Apple Vision）：中英文，accurate，开语言校正（ARCHITECTURE §5）。
enum ImageOCR {
    /// 扫描版 PDF 最多 OCR 这么多页。
    static let maxPDFPages = 30
    /// 渲染 PDF 页时长边的目标像素数。
    static let pdfRenderLongSide: CGFloat = 2_000

    private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        return request
    }

    private static func lines(from request: VNRecognizeTextRequest) -> [String] {
        (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// 图片文件（会按 EXIF 方向处理）。读不出图片时抛错。
    static func recognizeText(imageAt url: URL) throws -> String {
        let request = makeRequest()
        try VNImageRequestHandler(url: url, options: [:]).perform([request])
        return lines(from: request).joined(separator: "\n")
    }

    static func recognizeText(in image: CGImage) throws -> String {
        let request = makeRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return lines(from: request).joined(separator: "\n")
    }

    #if canImport(PDFKit)
    /// 扫描版 PDF：逐页渲染后 OCR，最多 `maxPages` 页（默认 `maxPDFPages`，测试里传小数字）。
    static func recognizeText(inPDFAt url: URL, maxPages: Int = maxPDFPages) throws -> String {
        guard let document = PDFDocument(url: url) else { throw PDFTextError.unreadable }
        var pages: [String] = []
        for index in 0..<min(document.pageCount, maxPages) {
            if Task.isCancelled { break }
            guard let page = document.page(at: index), let image = render(page) else { continue }
            let text = try recognizeText(in: image).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { pages.append(text) }
        }
        return pages.joined(separator: "\n\n")
    }

    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(4, pdfRenderLongSide / max(bounds.width, bounds.height))
        let width = Int((bounds.width * scale).rounded(.up))
        let height = Int((bounds.height * scale).rounded(.up))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
    #endif
}
#endif
