import Foundation

/// 输入框里的 http/https 链接（SPEC §3.2）：去重，按出现顺序，最多前 `limit` 个。
public enum LinkDetector {
    public static let defaultLimit = 5

    public static func links(in text: String, limit: Int = defaultLimit) -> [URL] {
        guard limit > 0, !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        let nsText = text as NSString
        var seen = Set<String>()
        var result: [URL] = []
        for match in detector.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            // NSDataDetector 会把 "example.com" 补成 http://example.com；这里只要用户写了协议的
            let written = nsText.substring(with: match.range).lowercased()
            guard written.hasPrefix("http://") || written.hasPrefix("https://") else { continue }
            guard seen.insert(url.absoluteString).inserted else { continue }
            result.append(url)
            if result.count == limit { break }
        }
        return result
    }
}
