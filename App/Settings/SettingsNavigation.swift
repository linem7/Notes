import Foundation
import NotesCore
import Observation

enum SettingsTab: Hashable {
    case general
    case connections
    case advanced
}

/// 设置窗口当前显示哪个标签页，以及 Connection 页要预选的模板。
/// 首次启动、还没有 Connection 时，打开 Connection 页并预选 DeepSeek（SPEC §8）。
@MainActor
@Observable
final class SettingsNavigation {
    var tab: SettingsTab = .general
    /// Connection 页出现时，用这个模板新建一个草稿，然后清空。
    var pendingTemplate: ConnectionTemplate?
    /// Connection 页出现时选中这个 Connection，然后清空（错误旁边的「打开设置」）。
    var pendingConnectionID: UUID?

    func showConnections(template: ConnectionTemplate? = nil) {
        tab = .connections
        pendingTemplate = template
    }

    func showConnection(_ connectionID: UUID) {
        tab = .connections
        pendingConnectionID = connectionID
    }
}
