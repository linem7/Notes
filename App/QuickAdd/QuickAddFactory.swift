import Foundation
import NotesCore

/// 把 Quick Add 的真实依赖接起来。App 生命周期（#10）在启动时调用：
///
/// ```swift
/// let store = QuickAddFactory.makeStore(files:…, noteStore:…, fetcher:…, organizer:…)
/// let controller = QuickAddController(store: store, context: context)
/// store.setHighlighter(boardController)
/// Hotkey.install { controller.toggle() }
/// ```
///
/// `organizer` 在 #6（Organizer）合并后换成包着它的 `ModelDraftOrganizer`，它每次 Organize 现取 Default Model、
/// Connection、Keychain 里的 key 和设置里的 prompt；没有可用的 Connection 时抛 `OrganizeSetupError.noConnection`。
@MainActor
enum QuickAddFactory {
    static func makeStore(
        files: MaterialFiles,
        noteStore: any NoteStoring,
        fetcher: (any WebPageFetching)?,
        organizer: any DraftOrganizing
    ) -> QuickAddStore {
        QuickAddStore(
            organizer: organizer,
            saver: QuickAddSaver(writer: MaterialFilesWriter(files: files), store: noteStore),
            makeIntake: { try FileQuickAddIntake(files: files, fetcher: fetcher) }
        )
    }
}

/// 占位：#8 合并后，`BoardController` 直接声明 `NoteHighlighting` 即可（它已经有 `highlight(noteIDs:)`）。
@MainActor
final class BoardHighlighterPlaceholder: NoteHighlighting {
    func highlight(noteIDs: [UUID]) {}
}
