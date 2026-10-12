import Testing
@testable import NotesCore

/// 期望值写死在这里：只比较 Parser 和 Board 的结果是否一致，两边一起错时发现不了。
struct DueDateTests {
    @Test(arguments: [
        ("2024-02-29", true),     // 闰年
        ("2000-02-29", true),     // 被 400 整除的世纪年是闰年
        ("2025-02-29", false),
        ("1900-02-29", false),    // 世纪年不被 400 整除，不是闰年
        ("2100-02-29", false),
        ("2026-04-31", false),
        ("2026-04-30", true),
        ("2026-12-31", true),
        ("2026-00-10", false),
        ("2026-13-01", false),
        ("2026-01-00", false),
        ("0001-01-01", true),
        ("9999-12-31", true),
        ("0000-01-01", false),    // 年份必须 >= 1
        ("0000-12-31", false),
        ("٢٠٢٦-١٠-١٥", false),    // 阿拉伯-印度数字
        ("２０２６-１０-１５", false), // 全角数字
        ("2026-1-5", false),
        ("26-10-15", false),
        ("2026/10/15", false),
        ("2026-10-15 ", false),   // 空白要由调用方先 trim
        ("2026-10-15\n", false),
        ("", false),
    ] as [(String, Bool)])
    func isValidDayHasFixedExpectations(day: String, expected: Bool) {
        #expect(DueDate.isValidDay(day) == expected)
    }
}
