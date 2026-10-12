import Foundation
import NotesCore

/// 把 Quick Add 的真实依赖接起来。App 生命周期（#10）在启动时调用：
///
/// ```swift
/// let store = QuickAddFactory.makeStore(files:…, fetcher:…, organizer:…, noteStore: { … })
/// let controller = QuickAddController(store: store, context: context)
/// store.setHighlighter(boardController)  // BoardController 遵守 NoteHighlighting
/// Hotkey.install { controller.toggle() }
/// ```
///
/// `organizer` 在 #6（Organizer）合并后换成包着它的 `ModelDraftOrganizer`，它每次 Organize 现取 Default Model、
/// Connection、Keychain 里的 key 和设置里的 prompt；没有可用的 Connection 时抛 `OrganizeSetupError.noConnection`。
///
/// `noteStore` 是**保存时现取**的（`ResolvingQuickAddSaver`）：所以数据库一开始打不开时 Quick Add 照样装得起来、
/// 能唤起、能 Organize，只是存不下（输入不丢）；Retry 成功之后不用重装也能存。
@MainActor
enum QuickAddFactory {
    static func makeStore(
        files: MaterialFiles,
        fetcher: (any WebPageFetching)?,
        organizer: any DraftOrganizing,
        noteStore: @escaping @Sendable () async -> (any NoteStoring)?
    ) -> QuickAddStore {
        QuickAddStore(
            organizer: organizer,
            saver: ResolvingQuickAddSaver(files: files, resolve: noteStore),
            makeIntake: { try FileQuickAddIntake(files: files, fetcher: fetcher) }
        )
    }
}

extension BoardController: NoteHighlighting {}
