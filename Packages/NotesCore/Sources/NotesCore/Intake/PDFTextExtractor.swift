import Foundation

#if canImport(PDFKit)
import PDFKit

enum PDFTextError: Error, Equatable {
    case unreadable
    case locked
}

/// PDF 在本地逐页抽取文字（SPEC §3.2）。
enum PDFTextExtractor {
    /// 抽到这么多字符就停：远超 MaterialBudget 的单个上限，不必读完几百页。
    static let characterLimit = 40_000

    /// 抽出的文字；整份 PDF 都没有文字（扫描版）时返回 nil。打不开或有密码时抛错。
    static func text(from url: URL, limit: Int = characterLimit) throws -> String? {
        guard let document = PDFDocument(url: url) else { throw PDFTextError.unreadable }
        if document.isLocked { throw PDFTextError.locked }
        var parts: [String] = []
        var count = 0
        for index in 0..<document.pageCount {
            if Task.isCancelled { break }
            guard let page = document.page(at: index)?.string else { continue }
            let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            parts.append(trimmed)
            count += trimmed.count
            if count >= limit { break }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
#endif
