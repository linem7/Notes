import Foundation

/// 把模型的输出解析成 Draft（ARCHITECTURE §4.3）。宽松解析，永远返回至少一条 Draft，不抛错。
public enum OrganizeResponseParser {
    /// 标题最多这么多字符（fallback 用输入第一行时截到这里）。
    static let fallbackTitleLimit = 80

    /// - Parameters:
    ///   - raw: 模型的完整输出。
    ///   - input: 用户在 Quick Add 里输入的原文，fallback 的 Title 取它的第一行。
    ///   - materialNames: 传给 Organize 的 Material 的名字（文件名 / 网页标题），按顺序；它的个数就是 Material 数量。
    ///     输入没有文字时，fallback 的 Title 取第一个 Material 的名字。
    /// - Returns: 解析出的 Draft；`materialIndices` 已经是从 0 开始、不越界，并且「没写 / 空」已展开成全部。
    ///   JSON 解析失败（含被截断的 JSON）或没有可用的条目时，返回一条 fallback Draft。
    public static func parse(_ raw: String, input: String, materialNames: [String] = []) -> [Draft] {
        let allMaterials = Array(materialNames.indices)
        guard let notes = notes(in: raw), !notes.isEmpty else {
            return [fallback(raw: raw, input: input, materialNames: materialNames)]
        }
        let drafts = notes.compactMap { draft(from: $0, allMaterials: allMaterials) }
        return drafts.isEmpty ? [fallback(raw: raw, input: input, materialNames: materialNames)] : drafts
    }

    // MARK: 解析

    /// 第一个 `{` 到最后一个 `}` 之间的 JSON（顺带去掉 ```json 围栏和前后的闲话）里的 `notes` 数组。
    private static func notes(in raw: String) -> [[String: Any]]? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8)) as? [String: Any],
              let notes = object["notes"] as? [Any] else { return nil }
        return notes.compactMap { $0 as? [String: Any] }
    }

    private static func draft(from note: [String: Any], allMaterials: [Int]) -> Draft? {
        guard let title = (note["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        var due: DueDate?
        if let day = validDay(note["due"]) {
            due = DueDate(day: day, time: validTime(note["time"]))
        }
        let detail = (note["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Draft(title: title, due: due, detail: detail, materialIndices: materialIndices(note["materials"], allMaterials: allMaterials))
    }

    /// prompt 里的序号从 1 开始；换算成从 0 开始，丢掉越界的和重复的。没写、写了空数组、或者写的全是越界序号，都算全部。
    private static func materialIndices(_ value: Any?, allMaterials: [Int]) -> [Int] {
        guard let numbers = value as? [Any] else { return allMaterials }
        let indices = Set(numbers.compactMap { element -> Int? in
            // JSON 里的 true / false 在 Foundation 里也是 NSNumber，不能当序号 1 / 0
            guard let number = element as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == number.doubleValue.rounded() else { return nil }
            return number.intValue - 1
        }.filter { allMaterials.contains($0) })
        return indices.isEmpty ? allMaterials : indices.sorted()
    }

    /// `yyyy-MM-dd` 并且是真实存在的日期；否则 nil。
    private static func validDay(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces),
              text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return text
    }

    /// `HH:mm`（24 小时制）；否则 nil。
    private static func validTime(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces),
              text.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else { return nil }
        return text
    }

    // MARK: fallback

    /// Title = 输入的第一行（最多 80 字符），Detail = 模型原文，挂全部 Material（SPEC §3.3）。
    /// 输入没有文字时 Title 取第一个 Material 的名字，什么都没有才是 "Untitled"。
    private static func fallback(raw: String, input: String, materialNames: [String]) -> Draft {
        let firstLine = input
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        let title = firstLine
            ?? materialNames.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            ?? "Untitled"
        return Draft(
            title: String(title.prefix(fallbackTitleLimit)),
            detail: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            materialIndices: Array(materialNames.indices)
        )
    }
}
