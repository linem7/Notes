import Foundation

/// Note 的截止日期（ARCHITECTURE §3.1）。
public struct DueDate: Codable, Hashable, Sendable {
    /// 本地日历日 "yyyy-MM-dd"，不随时区漂移。
    public var day: String
    /// "HH:mm"，可选。
    public var time: String?

    public init(day: String, time: String? = nil) {
        self.day = day
        self.time = time
    }

    /// 是不是真实存在的公历日期，格式严格为 `yyyy-MM-dd`（ASCII 数字，不含空白）。
    /// Board 分组和 Organize 解析共用。每次调用新建 Calendar，不依赖当前时区或语言。
    static func isValidDay(_ day: String) -> Bool {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.map(\.count) == [4, 2, 2],
              let year = Int(parts[0]), let month = Int(parts[1]), let d = Int(parts[2]),
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return false }
        return DateComponents(calendar: Calendar(identifier: .gregorian), year: year, month: month, day: d).isValidDate
    }
}
