import Foundation

/// 添加 Connection 时先选的模板（SPEC §4）：填好 base URL，用户只需要粘贴 key。
/// 界面标题在 App 层（需要本地化）。
public enum ConnectionTemplate: CaseIterable, Identifiable, Sendable {
    case deepSeek
    case openRouter
    case bailian
    case custom

    public var id: Self { self }

    public func makeConnection() -> Connection {
        switch self {
        case .deepSeek: .deepSeek()
        case .openRouter: .openRouter()
        case .bailian: .bailian()
        case .custom: .custom(baseURL: URL(string: "https://")!)
        }
    }
}

/// 编辑中的 Connection。API key 单独放着，留空表示沿用 Keychain 里已经保存的。
public struct ConnectionDraft: Sendable {
    public let id: UUID
    public var name: String
    public var baseURL: String
    public var apiKey = ""
    public var models: [ModelInfo]
    public var hiddenModelIDs: Set<String>
    /// 用户手动填写的模型 ID，重新拉取时保留。
    public var manualModelIDs: [String]
    /// 还没保存过。
    public var isNew: Bool
    /// 已保存的 Connection 的 base URL 的来源（scheme、host、端口）。保存过的 key 只属于这个来源。
    private let savedOrigin: String?

    public init(template: ConnectionTemplate, name: String? = nil) {
        let connection = template.makeConnection()
        id = connection.id
        self.name = name ?? connection.name
        baseURL = template == .custom ? "" : connection.baseURL.absoluteString
        models = []
        hiddenModelIDs = []
        manualModelIDs = []
        isNew = true
        savedOrigin = nil
    }

    public init(connection: Connection, manualModelIDs: [String]) {
        id = connection.id
        name = connection.name
        baseURL = connection.baseURL.absoluteString
        models = connection.models
        hiddenModelIDs = connection.hiddenModelIDs
        self.manualModelIDs = manualModelIDs
        isNew = false
        savedOrigin = Self.origin(of: connection.baseURL.absoluteString)
    }

    /// 来源：scheme、host、端口，小写。解析不出来时为 nil。
    static func origin(of baseURL: String) -> String? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
        return "\(scheme)://\(host):\(url.port.map(String.init) ?? "")"
    }

    /// 编辑已保存的 Connection 时 base URL 的来源变了：Keychain 里存的 key 不能发到新地址，必须重新粘贴。
    public var requiresNewKey: Bool {
        guard !isNew else { return false }
        return Self.origin(of: baseURL) != savedOrigin
    }

    /// 这次保存和连接测试用哪个 key：粘贴的新 key 优先；没粘贴时只有来源没变才沿用已保存的。
    public func effectiveKey(pasted: String, saved: String?) -> String? {
        let pasted = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pasted.isEmpty { return pasted }
        return requiresNewKey ? nil : saved
    }

    /// base URL 不是合法的 http(s) 地址时返回 nil。
    public func makeConnection() -> Connection? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)),
              url.scheme == "https" || url.scheme == "http", url.host() != nil
        else { return nil }
        let name = name.trimmingCharacters(in: .whitespaces)
        return Connection(
            id: id,
            name: name.isEmpty ? (url.host() ?? "") : name,
            baseURL: url,
            hiddenModelIDs: hiddenModelIDs,
            models: models
        )
    }

    /// 拉取到的列表加上手动填写、而列表里没有的模型；手填的 ID 这次拉到了，就不再算手动的。
    /// 返回合并后的 Model 列表和更新后的手动 ID。
    public func merging(fetched: [ModelInfo]) -> (models: [ModelInfo], manualModelIDs: [String]) {
        let fetchedIDs = Set(fetched.map(\.id))
        let manual = manualModelIDs.filter { !fetchedIDs.contains($0) }
        return (fetched + models.filter { manual.contains($0.id) }, manual)
    }
}
