import Foundation

/// 文本文件的解码（移植自 Chatbot 的 AttachmentIntake）。
enum TextDecoder {
    /// 读文本文件时最多解码这么多字节；Organize 的上限远小于它（MaterialBudget）。
    static let byteLimit = 1_000_000

    /// - Parameter truncated: `data` 是被截断的文件开头，末尾可能切在一个字符中间，解码失败时往回退几个字节再试。
    static func decode(_ data: Data, truncated: Bool = false) -> String? {
        let bytes = [UInt8](data)
        // UTF-16 和 UTF-32 带 BOM 时会有 NUL 字节，要在二进制检查之前处理。
        // UTF-32 LE 的 BOM（FF FE 00 00）以 UTF-16 LE 的 BOM 开头，所以先判断 UTF-32
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return decode(bytes.dropFirst(4), as: .utf32LittleEndian, unit: 4, truncated: truncated)
        }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return decode(bytes.dropFirst(4), as: .utf32BigEndian, unit: 4, truncated: truncated)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return decode(bytes.dropFirst(2), as: .utf16LittleEndian, unit: 2, truncated: truncated)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return decode(bytes.dropFirst(2), as: .utf16BigEndian, unit: 2, truncated: truncated)
        }
        // 前 8KB 里有 NUL 字节，就当成二进制文件（Office 文档、压缩包、可执行文件……）
        if bytes.prefix(8_192).contains(0) { return nil }

        // UTF-8 的一个字符最多 4 字节，截断时最多往回退 3 个
        for trim in 0...(truncated ? 3 : 0) {
            if var text = String(validating: bytes.dropLast(trim), as: UTF8.self) {
                if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
                return text
            }
        }
        return detectEncoding(data)
    }

    /// 去掉 BOM 之后按指定编码解码。截断时先丢掉不足一个单元的尾巴，必要时再退一个单元（代理对被切开）。
    private static func decode(_ bytes: ArraySlice<UInt8>, as encoding: String.Encoding, unit: Int, truncated: Bool) -> String? {
        let whole = bytes.count - bytes.count % unit
        for extra in (truncated ? [0, unit] : [0]) where whole - extra >= 0 {
            if let text = String(data: Data(bytes.prefix(whole - extra)), encoding: encoding) { return text }
        }
        return nil
    }

    /// UTF-8 失败时用系统的编码检测（例如 GBK、Shift_JIS 的旧文件）。
    private static func detectEncoding(_ data: Data) -> String? {
        #if canImport(Darwin)
        var converted: NSString?
        var usedLossyConversion: ObjCBool = false
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [.allowLossyKey: false],
            convertedString: &converted,
            usedLossyConversion: &usedLossyConversion
        )
        guard encoding != 0, let converted else { return nil }
        return converted as String
        #else
        return nil
        #endif
    }
}
