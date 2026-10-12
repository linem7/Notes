import Foundation

/// Organize 一次调用要的设置，由 App 从 ConnectionStore / APIKeyStore / Default Model / 设置里的 prompt 取。
public struct OrganizeConfiguration: Sendable {
    public var connection: Connection
    public var modelID: String
    public var apiKey: String
    public var userPrompt: String

    public init(connection: Connection, modelID: String, apiKey: String, userPrompt: String = OrganizePrompt.default) {
        self.connection = connection
        self.modelID = modelID
        self.apiKey = apiKey
        self.userPrompt = userPrompt
    }
}

/// 真实的 `DraftOrganizing`：取设置，调 `Organizer`（截断由它按 `MaterialBudget` 做）。
public struct ModelDraftOrganizer: DraftOrganizing {
    private let organizer: Organizer
    /// 每次 Organize 现取；没有 Connection、Model 或 key 时返回 nil。
    private let configuration: @Sendable () -> OrganizeConfiguration?

    public init(
        organizer: Organizer = Organizer(),
        configuration: @escaping @Sendable () -> OrganizeConfiguration?
    ) {
        self.organizer = organizer
        self.configuration = configuration
    }

    public func organize(
        input: String,
        materials: [OrganizeMaterial],
        onProgress: (@Sendable (Int) -> Void)?
    ) async throws -> [Draft] {
        guard let configuration = configuration() else { throw OrganizeSetupError.noConnection }
        return try await organizer.organize(
            input: input,
            materials: materials,
            connection: configuration.connection,
            modelID: configuration.modelID,
            apiKey: configuration.apiKey,
            userPrompt: configuration.userPrompt,
            onProgress: onProgress
        )
    }
}
