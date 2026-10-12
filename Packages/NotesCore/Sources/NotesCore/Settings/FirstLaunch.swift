import Foundation

/// 是不是第一次启动（SPEC §8）。初始化时读到标记的同时立刻写入，所以即使首次启动流程中途退出，下次也不再算首次。
public struct FirstLaunch: Sendable {
    private static let launchedKey = "hasLaunchedBefore"

    public let isFirstLaunch: Bool

    public init(defaults: UserDefaults = .standard) {
        isFirstLaunch = !defaults.bool(forKey: Self.launchedKey)
        defaults.set(true, forKey: Self.launchedKey)
    }
}
