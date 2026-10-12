import Foundation
import Testing
@testable import NotesCore

struct OrganizePromptTests {
    /// 2026-10-12 12:00 UTC 是星期一。
    private let now = Date(timeIntervalSince1970: 1_791_806_400)

    @Test func systemPromptStartsWithDateWeekdayAndTimeZone() {
        let system = OrganizePrompt.system(now: now, timeZone: TimeZone(identifier: "Asia/Shanghai")!, prompt: "PROMPT")
        #expect(system == "Today is 2026-10-12 (Monday), time zone Asia/Shanghai.\n\nPROMPT")
    }

    @Test func dateFollowsTheTimeZone() {
        // 同一时刻在东京已经是下一天
        let late = Date(timeIntervalSince1970: 1_791_806_400 + 14 * 3600)
        let utc = OrganizePrompt.system(now: late, timeZone: TimeZone(identifier: "Africa/Abidjan")!, prompt: "")
        let tokyo = OrganizePrompt.system(now: late, timeZone: TimeZone(identifier: "Asia/Tokyo")!, prompt: "")
        #expect(utc.hasPrefix("Today is 2026-10-13 (Tuesday), time zone Africa/Abidjan."))
        #expect(tokyo.hasPrefix("Today is 2026-10-13 (Tuesday), time zone Asia/Tokyo."))
        let earlier = OrganizePrompt.system(now: now.addingTimeInterval(-13 * 3600), timeZone: TimeZone(identifier: "Pacific/Honolulu")!, prompt: "")
        #expect(earlier.hasPrefix("Today is 2026-10-11 (Sunday), time zone Pacific/Honolulu."))
    }

    @Test func systemPromptUsesTheDefaultWhenNoneIsGiven() {
        #expect(OrganizePrompt.system(now: now, timeZone: TimeZone(identifier: "UTC")!).hasSuffix(OrganizePrompt.default))
    }

    @Test func defaultPromptIsEnglishAndDescribesTheOutputFormat() {
        let prompt = OrganizePrompt.default
        #expect(prompt.unicodeScalars.allSatisfy { $0.value < 0x2E80 })
        for needle in ["\"notes\"", "\"title\"", "\"due\"", "\"time\"", "\"detail\"", "\"materials\"", "main language of the input", "Never make one up"] {
            #expect(prompt.contains(needle), "missing \(needle)")
        }
    }

    // MARK: 用户消息

    @Test func userMessageWithoutMaterials() {
        #expect(OrganizePrompt.userMessage(input: "hello", materials: []) == "<input>\nhello\n</input>")
    }

    @Test func userMessageSnapshot() {
        let message = OrganizePrompt.userMessage(input: "Please review the attached", materials: [
            PromptMaterial(kind: .file, name: "contract.pdf", text: "Clause 1\nClause 2"),
            PromptMaterial(kind: .webPage, name: "Example", url: "https://example.com/a?x=1&y=2", title: "Example Page", text: "Body text"),
            PromptMaterial(kind: .file, name: "quote.xlsx"),
            PromptMaterial(kind: .webPage, name: "https://down.example.com", url: "https://down.example.com"),
        ])
        #expect(message == """
        <input>
        Please review the attached
        </input>

        <material index="1" kind="file" name="contract.pdf">
        Clause 1
        Clause 2
        </material>

        <material index="2" kind="webpage" url="https://example.com/a?x=1&amp;y=2" title="Example Page">
        Body text
        </material>

        <material index="3" kind="file" name="quote.xlsx" readable="false"/>

        <material index="4" kind="webpage" url="https://down.example.com" title="https://down.example.com" readable="false"/>
        """)
    }

    @Test func attributeValuesAreEscaped() {
        let message = OrganizePrompt.userMessage(input: "x", materials: [
            PromptMaterial(kind: .file, name: "a\"b<c>&\nd.txt", text: "t"),
        ])
        #expect(message.contains("name=\"a&quot;b&lt;c>&amp; d.txt\""))
    }
}
