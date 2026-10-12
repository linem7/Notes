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

    /// 从模型输出里取出条目，按顺序试，前一步取不到才试下一步：
    /// 1. 去掉 ``` 围栏行后整体当 JSON：`{"notes": […]}`、裸数组 `[{…}, …]`、不带外壳的单个对象 `{"title": …}`；
    /// 2. 第一个 `{` 到最后一个 `}` 之间（前后有闲话）；
    /// 3. 第一个 `[` 到最后一个 `]` 之间（前后有闲话，条目是裸数组）。
    /// 闲话里自己带了大括号 / 方括号的，这些步骤都会失败，走 fallback。
    private static func notes(in raw: String) -> [[String: Any]]? {
        let text = stripFences(raw)
        let candidates: [Any?] = [
            try? JSONSerialization.jsonObject(with: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)),
            json(in: text, from: "{", to: "}"),
            json(in: text, from: "[", to: "]"),
        ]
        for case let candidate? in candidates {
            if let notes = notes(from: candidate) { return notes }
        }
        return nil
    }

    private static func notes(from json: Any) -> [[String: Any]]? {
        if let object = json as? [String: Any] {
            if let notes = object["notes"] as? [Any] { return notes.compactMap { $0 as? [String: Any] } }
            return object["title"] != nil ? [object] : nil
        }
        if let array = json as? [Any] {
            let objects = array.compactMap { $0 as? [String: Any] }
            return objects.isEmpty ? nil : objects
        }
        return nil
    }

    /// 只去掉围栏标记本身，内容一个字都不删：行首的 ```lang（语言标记后面可以直接跟 JSON）和行尾的 ```。
    /// 模型有时把围栏和 JSON 写在同一行，如 ```json{"notes": […]}```。
    private static func stripFences(_ raw: String) -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("```") {
                text.removeFirst(3)
                text = String(text.drop { $0.isASCII && ($0.isLetter || $0.isNumber) || "_+-".contains($0) })
            }
            if text.hasSuffix("```") { text.removeLast(3) }
            return text
        }.joined(separator: "\n")
    }

    private static func json(in raw: String, from open: Character, to close: Character) -> Any? {
        guard let start = raw.firstIndex(of: open), let end = raw.lastIndex(of: close), start < end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8))
    }

    private static func draft(from note: [String: Any], allMaterials: [Int]) -> Draft? {
        guard let title = singleLine(note["title"] as? String), !title.isEmpty else { return nil }
        var due: DueDate?
        if let day = validDay(note["due"]) {
            due = DueDate(day: day, time: validTime(note["time"]))
        }
        let detail = (note["detail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Draft(title: title, due: due, detail: detail, materialIndices: materialIndices(note["materials"], allMaterials: allMaterials))
    }

    /// Title 是一句话：换行折成空格，连续空白合并成一个，首尾空白去掉。
    private static func singleLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// prompt 里的序号从 1 开始；换算成从 0 开始，丢掉越界的和重复的。没写、写了空数组、或者写的全是越界序号，都算全部。
    private static func materialIndices(_ value: Any?, allMaterials: [Int]) -> [Int] {
        guard let numbers = value as? [Any] else { return allMaterials }
        let indices = Set(numbers.compactMap { element -> Int? in
            // JSON 里的 true / false 在 Foundation 里也是 NSNumber，不能当序号 1 / 0。
            // CFBooleanGetTypeID 只在 Darwin 上有；NotesCore 只支持 macOS（Package.swift），CI 也只跑 macOS。
            guard let number = element as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            // 先在 Double 上判断范围和整数，再转 Int：模型给出 -9223372036854775808、1e30 这类值时不能溢出
            let value = number.doubleValue
            guard value == value.rounded(), value >= 1, value <= Double(allMaterials.count) else { return nil }
            return Int(value) - 1
        })
        return indices.isEmpty ? allMaterials : indices.sorted()
    }

    /// `yyyy-MM-dd` 并且是真实存在的日期；否则 nil。
    private static func validDay(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              DueDate.isValidDay(text) else { return nil }
        return text
    }

    /// `HH:mm`（24 小时制）；否则 nil。
    private static func validTime(_ value: Any?) -> String? {
        // 要去掉换行：正则的 `$` 会匹配末尾换行之前，"09:00\n" 否则会带着换行存进去
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil else { return nil }
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
