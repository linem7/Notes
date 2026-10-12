import AppKit
import NotesCore
import Observation
import os

/// Organize 一次调用需要的设置，每次现取（Default Model、Connection、Keychain 里的 key、设置里的 prompt）。
struct ResolvedOrganizeSettings: Sendable {
    var connection: Connection
    var modelID: String
    var apiKey: String
    var prompt: String
}

/// 菜单栏、设置窗口和 Quick Add 共用的 app 级状态。由 `AppDelegate` 持有。
@MainActor
@Observable
final class AppServices {
    let connections = ConnectionStore()
    let apiKeys = APIKeyStore()
    let launchAtLogin = LaunchAtLogin()
    let navigation = SettingsNavigation()
    let board = BoardProxy()
    let badge = MenuBarBadge()
    let firstLaunch: FirstLaunch
    /// 本次启动时生效的界面语言；设置里选了别的，就提示重启。
    let launchLanguage: AppLanguage

    /// 数据存储；打开失败时为 nil（Advanced 页的数据操作不可用）。
    var noteStore: (any NoteStoring)?

    /// 由 App 入口在场景创建后接上（打开设置要用 SwiftUI 的环境值）。
    @ObservationIgnored var openSettings: () -> Void = {}
    /// 菜单栏 New Note：打开 Quick Add。由 Quick Add（#9）接上。
    /// 首次启动的设置窗口只自动打开一次。
    @ObservationIgnored var didOpenFirstLaunchSettings = false
    @ObservationIgnored var openQuickAdd: () -> Void = {}

    /// 先写界面语言再创建（SwiftUI 读 `AppleLanguages` 在这之后）。
    static func make() -> AppServices {
        AppLanguage.applyInitialDefault()
        return AppServices()
    }

    private init() {
        firstLaunch = FirstLaunch()
        launchLanguage = AppLanguage.stored()
    }

    /// Organize 现取的设置；没有 Default Model 或 key 时为 nil（Draft 区提示先添加 Connection）。
    func resolvedOrganizeSettings(defaultPrompt: String) -> ResolvedOrganizeSettings? {
        guard let (connection, modelID) = connections.resolvedDefaultModel(),
              let key = (try? apiKeys.apiKey(for: connection.id)) ?? nil else { return nil }
        return ResolvedOrganizeSettings(
            connection: connection, modelID: modelID, apiKey: key,
            prompt: OrganizePromptSetting.text(defaultText: defaultPrompt)
        )
    }

    /// 「Connection / Model」，Quick Add 顶栏显示；没有 Default Model 时为 nil。
    var modelLabel: String? {
        guard let (connection, modelID) = connections.resolvedDefaultModel() else { return nil }
        let name = connection.models.first { $0.id == modelID }?.displayName ?? modelID
        return "\(connection.name) / \(name)"
    }
}
