import Foundation

/// 交给模型的文字上限（ARCHITECTURE §4.1，L2，可以以后调）。超出的截断，末尾加标注。
/// 只截发给模型的文字，存储里的原文不动。
public struct MaterialBudget: Hashable, Sendable {
    public var perMaterial: Int
    public var total: Int
    public var source: Int

    public static let `default` = MaterialBudget(perMaterial: 20_000, total: 60_000, source: 20_000)
    public static let truncationMarker = "（后文已截断 / truncated）"

    public init(perMaterial: Int, total: Int, source: Int) {
        self.perMaterial = perMaterial
        self.total = total
        self.source = source
    }

    public struct Result: Hashable, Sendable {
        public var source: String
        /// 和输入的 Material 一一对应；没有 Readable Text 的是 nil。
        public var materials: [String?]
    }

    /// - Parameters:
    ///   - source: 用户输入的原文。
    ///   - materialTexts: 各 Material 的 Readable Text，按发给模型的顺序；没有的传 nil。
    public func apply(source: String, materialTexts: [String?]) -> Result {
        var remaining = total
        let materials = materialTexts.map { text -> String? in
            guard let text else { return nil }
            let limit = min(perMaterial, remaining)
            let (truncated, wasCut) = Self.truncate(text, to: limit)
            remaining -= truncated.count
            return wasCut ? truncated + Self.truncationMarker : truncated
        }
        let (sourceText, sourceCut) = Self.truncate(source, to: self.source)
        return Result(source: sourceCut ? sourceText + Self.truncationMarker : sourceText, materials: materials)
    }

    /// 超过 `limit` 个字符就截到 `limit`；刚好等于 `limit` 不算超出。
    static func truncate(_ text: String, to limit: Int) -> (text: String, wasCut: Bool) {
        let limit = max(0, limit)
        guard let end = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex), end != text.endIndex else {
            return (text, false)
        }
        return (String(text[..<end]), true)
    }
}
