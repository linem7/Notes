import Foundation
import Observation

/// 指向某个 Connection 下的一个 Model。
public struct ModelRef: Codable, Hashable, Sendable {
    public var connectionID: UUID
    public var modelID: String

    public init(connectionID: UUID, modelID: String) {
        self.connectionID = connectionID
        self.modelID = modelID
    }
}

/// Connection 列表和 Default Model，以 JSON 存在 UserDefaults（移植 Chatbot 的 `ConnectionStore`）。
/// API key 不在这里，在 Keychain（App 的 `APIKeyStore`）。
@MainActor
@Observable
public final class ConnectionStore {
    private static let connectionsKey = "connections"
    private static let defaultModelKey = "defaultModel"
    private static let manualModelIDsKey = "manualModelIDs"

    @ObservationIgnored private let defaults: UserDefaults
    public private(set) var connections: [Connection]
    public var defaultModel: ModelRef? {
        didSet { Self.write(defaultModel, forKey: Self.defaultModelKey, to: defaults) }
    }

    /// 每个 Connection 里用户手动填写的模型 ID（key 是 Connection ID）。重新拉取 Model 列表时保留它们，
    /// 免得 `/models` 返回的列表不全时用户补的 ID 被冲掉。
    @ObservationIgnored private var manualModelIDs: [String: [String]]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        connections = Self.read([Connection].self, forKey: Self.connectionsKey, from: defaults) ?? []
        defaultModel = Self.read(ModelRef.self, forKey: Self.defaultModelKey, from: defaults)
        manualModelIDs = Self.read([String: [String]].self, forKey: Self.manualModelIDsKey, from: defaults) ?? [:]
    }

    public func manualModelIDs(of connectionID: UUID) -> [String] {
        manualModelIDs[connectionID.uuidString] ?? []
    }

    public func setManualModelIDs(_ ids: [String], of connectionID: UUID) {
        manualModelIDs[connectionID.uuidString] = ids.isEmpty ? nil : ids
        Self.write(manualModelIDs, forKey: Self.manualModelIDsKey, to: defaults)
    }

    public func connection(id: UUID) -> Connection? {
        connections.first { $0.id == id }
    }

    /// 新增或更新一个 Connection。还没有 Default Model 时，用它的第一个 Model。
    public func save(_ connection: Connection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
        } else {
            connections.append(connection)
        }
        Self.write(connections, forKey: Self.connectionsKey, to: defaults)
        if defaultModel == nil, let model = preferredDefaultModel(of: connection) {
            defaultModel = ModelRef(connectionID: connection.id, modelID: model.id)
        }
    }

    /// 删除一个 Connection。Default Model 属于它时清空，由用户在 General 页重新选。
    /// 它的 Keychain key 由调用方删除。
    public func delete(_ connectionID: UUID) {
        connections.removeAll { $0.id == connectionID }
        Self.write(connections, forKey: Self.connectionsKey, to: defaults)
        setManualModelIDs([], of: connectionID)
        if defaultModel?.connectionID == connectionID { defaultModel = nil }
    }

    /// 还没有 Default Model 时选哪个：DeepSeek 官方优先 `deepseek-flash`（SPEC §4），否则取列表里第一个可见的。
    /// 不依赖 `/models` 返回的顺序。
    private func preferredDefaultModel(of connection: Connection) -> ModelInfo? {
        let visible = visibleModels(of: connection)
        if connection.platform == .deepSeek, let flash = visible.first(where: { $0.id == "deepseek-flash" }) {
            return flash
        }
        return visible.first
    }

    /// Default Model 选择器里列出的 Model：去掉隐藏的。
    public func visibleModels(of connection: Connection) -> [ModelInfo] {
        connection.models.filter { !connection.hiddenModelIDs.contains($0.id) }
    }

    /// Default Model 解析成可以直接交给 Organizer 的 Connection 和 Model ID；没设置或已被删掉时为 nil。
    public func resolvedDefaultModel() -> (connection: Connection, modelID: String)? {
        guard let ref = defaultModel, let connection = connection(id: ref.connectionID) else { return nil }
        return (connection, ref.modelID)
    }

    private static func read<T: Decodable>(_ type: T.Type, forKey key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T?, forKey key: String, to defaults: UserDefaults) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
