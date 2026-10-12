import Foundation

/// 交给 Organize 的一个 Material（已经按 `MaterialBudget` 截断过）。
public struct PromptMaterial: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case file
        case webPage = "webpage"
    }

    public var kind: Kind
    /// 文件名；Web Page 是页面标题或 URL。
    public var name: String
    /// Web Page 的 URL。
    public var url: String?
    /// Web Page 的标题。
    public var title: String?
    /// Readable Text；nil 表示没有（模型只看到文件名）。
    public var text: String?

    public init(kind: Kind, name: String, url: String? = nil, title: String? = nil, text: String? = nil) {
        self.kind = kind
        self.name = name
        self.url = url
        self.title = title
        self.text = text
    }
}

/// Organize 的 prompt（ARCHITECTURE §4.1，SPEC §4）。
public enum OrganizePrompt {
    /// 内置的 Organize prompt，用户可以在设置里改、恢复默认就是回到这个。当前日期、星期和时区不在这里，
    /// 由 `system(now:timeZone:prompt:)` 加在最前面。
    public static let `default` = """
    You turn what the user gives you into simple, clear notes.

    The user message may contain an <input> block (text the user typed or pasted, for example a chat conversation) \
    and zero or more <material> blocks (files and web pages, numbered from 1). The materials can be the only input. \
    A material marked readable="false" has no readable text: you only know its name.

    Rules:
    - Write the notes in the main language of the input: Chinese input gives Chinese notes, English input gives English notes.
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

    Example (today is 2026-10-12, a Monday). Input: "Alex needs the signed contract by Thursday 3pm, email it to alex@example.com"
    {"notes": [{"title": "Send the signed contract to Alex", "due": "2026-10-15", "time": "15:00", \
    "detail": "- Sign the contract\\n- Email it to alex@example.com", "materials": []}]}

    Example. Input: "buy milk"
    {"notes": [{"title": "Buy milk", "due": null, "time": null, "detail": "", "materials": []}]}
    """

    /// system prompt = 第一行日期、星期、时区 + 用户可编辑的 prompt。
    public static func system(
        now: Date,
        timeZone: TimeZone = .current,
        prompt: String = OrganizePrompt.default
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd (EEEE)"
        return "Today is \(formatter.string(from: now)), time zone \(timeZone.identifier).\n\n\(prompt)"
    }

    /// 用户消息：`<input>` 加每个 Material 一个 `<material>`（序号从 1 开始）。
    public static func userMessage(input: String, materials: [PromptMaterial]) -> String {
        // 只有 Material、没有文字时不写 <input> 块（SPEC §3.3）；两样都没有时才留一个空的，免得消息是空串
        var parts: [String] = []
        if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || materials.isEmpty {
            parts.append("<input>\n\(input)\n</input>")
        }
        for (offset, material) in materials.enumerated() {
            var attributes = "index=\"\(offset + 1)\" kind=\"\(material.kind.rawValue)\""
            switch material.kind {
            case .file:
                attributes += " name=\"\(escape(material.name))\""
            case .webPage:
                if let url = material.url { attributes += " url=\"\(escape(url))\"" }
                attributes += " title=\"\(escape(material.title ?? material.name))\""
            }
            if let text = material.text {
                parts.append("<material \(attributes)>\n\(text)\n</material>")
            } else {
                parts.append("<material \(attributes) readable=\"false\"/>")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func escape(_ attribute: String) -> String {
        attribute
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
