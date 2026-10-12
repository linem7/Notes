import SwiftUI

@main
struct NotesApp: App {
    var body: some Scene {
        MenuBarExtra("Notes", systemImage: "note.text") {
            Button("Quit Notes") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }

        // 空壳：设置页在 ARCHITECTURE §11 第 9 步实现
        Settings {
            Color.clear.frame(width: 420, height: 240)
        }
    }
}
