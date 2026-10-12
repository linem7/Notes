import Foundation
import Observation

/// 菜单栏和设置页需要从 Board 拿到的东西。
@MainActor
protocol BoardControlling: AnyObject {
    var mode: BoardMode { get set }
    var isVisible: Bool { get }
    func show()
    func hide()
}

/// 菜单栏和设置页共用的 Board 入口。窗口在 app 启动完成后才创建，所以先于 `BoardController` 存在，之后再接上。
/// Board Mode 存在 UserDefaults（和 `BoardController` 同一个 key），改它会同步给窗口。
@MainActor
@Observable
final class BoardProxy {
    private static let modeKey = "boardMode"

    @ObservationIgnored private weak var controller: (any BoardControlling)?
    @ObservationIgnored private let defaults: UserDefaults

    var mode: BoardMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Self.modeKey)
            controller?.mode = mode
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.modeKey).flatMap(BoardMode.init(rawValue:)) ?? .onDesktop
    }

    func attach(_ controller: any BoardControlling) {
        self.controller = controller
        controller.mode = mode
    }

    func show() { controller?.show() }
}

extension BoardController: BoardControlling {}
