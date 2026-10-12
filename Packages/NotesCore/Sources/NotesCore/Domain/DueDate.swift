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
}
