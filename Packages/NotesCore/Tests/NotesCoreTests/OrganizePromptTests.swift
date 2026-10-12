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
        for needle in ["\"notes\"", "\"title\"", "\"due\"", "\"time\"", "\"detail\"", "\"materials\"", "main language of the input (or of the materials when there is no input)", "assume today is", "Never make one up"] {
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

    // MARK: 默认 prompt

    @Test func defaultPromptHasNoDateLine() {
        // 日期、星期、时区由 system(now:timeZone:prompt:) 加在最前面，不在可编辑的文字里
        #expect(!OrganizePrompt.default.contains("Today is"))
    }

    @Test func defaultPromptCoversTheSpecRules() {
        let prompt = OrganizePrompt.default
        for needle in [
            "starts with a verb",                                   // Title 动词开头
            "Keep what is needed to act: names, places, numbers, links",  // Detail 留关键信息
            "Do not retell unrelated chat",
            "several independent things",                           // 拆分
            "Sub-steps of one thing belong in its detail",
            "Never make one up",                                    // 不编 Due Date
            "Chinese input gives Chinese notes",                    // 语言跟随输入
            "Example",                                              // 有示例
        ] {
            #expect(prompt.contains(needle), "missing \(needle)")
        }
        #expect(!prompt.contains("to-do"))    // CONTEXT.md 的 Avoid 列表里没有，但 Note 不叫 to-do
    }

    @Test func defaultPromptSnapshot() {
        #expect(OrganizePrompt.default == """
        You turn what the user gives you into simple, clear notes.

        The user message may contain an <input> block (text the user typed or pasted, for example a chat conversation) \
        and zero or more <material> blocks (files and web pages, numbered from 1). The materials can be the only input. \
        A material marked readable="false" has no readable text: you only know its name.

        Rules:
        - Write the notes in the main language of the input (or of the materials when there is no input): Chinese input gives Chinese notes, English input gives English notes.
        - title: one sentence that starts with a verb and says what to do.
        - detail: short Markdown, a few bullet points. Keep what is needed to act: names, places, numbers, links, things to prepare. \
        Do not retell unrelated chat.
        - due: the deadline as a date in yyyy-MM-dd, or null. Work out phrases like "next Wednesday" or "tomorrow afternoon" \
        from today's date given at the top. If the deadline cannot be read from the content, use null. Never make one up.
        - time: the time of the deadline as HH:mm (24-hour), or null. Only when due is not null.
        - If the input holds several independent things to do, make one note for each. Sub-steps of one thing belong in its detail.
        - materials: the numbers of the <material> blocks this note needs. Leave it out or use [] when the note uses all of them.

        Reply with a single JSON object and nothing else, in exactly this shape:
        {"notes": [{"title": "...", "due": "yyyy-MM-dd" or null, "time": "HH:mm" or null, "detail": "...", "materials": [1, 2]}]}

        Example (assume today is 2026-10-12, a Monday; the real date is given at the top). Input: "Alex needs the signed contract by Thursday 3pm, email it to alex@example.com"
        {"notes": [{"title": "Send the signed contract to Alex", "due": "2026-10-15", "time": "15:00", \
        "detail": "- Sign the contract\\n- Email it to alex@example.com", "materials": []}]}

        Example. Input: "buy milk"
        {"notes": [{"title": "Buy milk", "due": null, "time": null, "detail": "", "materials": []}]}
        """)
    }

    @Test func userMessageOmitsTheInputBlockWhenThereIsNoText() {
        let message = OrganizePrompt.userMessage(input: "  \n", materials: [
            PromptMaterial(kind: .file, name: "contract.pdf", text: "Clause 1"),
        ])
        #expect(message == """
        <material index="1" kind="file" name="contract.pdf">
        Clause 1
        </material>
        """)
        #expect(!message.contains("<input>"))
    }

    @Test func userMessageKeepsAnEmptyInputBlockOnlyWhenThereIsNothingElse() {
        #expect(OrganizePrompt.userMessage(input: "", materials: []) == "<input>\n\n</input>")
    }
}
