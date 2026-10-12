import NotesCore
import SwiftUI

/// 编辑一条 Note：Title、Due Date（可清除、可选时间）、Detail 源码；可以删除单个 Material、拖入 File。
/// ⌘⏎ 保存，Esc 放弃（SPEC §2.3）。保存只提交 title、due、detail。
struct NoteEditor: View {
    let item: NoteWithMaterials
    let calendar: Calendar
    let files: MaterialFiles
    let opener: any URLOpening
    var onSave: (_ title: String, _ due: DueDate?, _ detail: String) -> Void
    var onCancel: () -> Void
    var onAddFiles: ([URL]) -> Void
    var onDeleteMaterial: (UUID) -> Void

    @State private var title: String
    @State private var detail: String
    @State private var hasDue: Bool
    @State private var includesTime: Bool
    @State private var dueDate: Date
    @State private var isDropTargeted = false

    init(
        item: NoteWithMaterials, calendar: Calendar, files: MaterialFiles, opener: any URLOpening,
        onSave: @escaping (String, DueDate?, String) -> Void, onCancel: @escaping () -> Void,
        onAddFiles: @escaping ([URL]) -> Void, onDeleteMaterial: @escaping (UUID) -> Void
    ) {
        self.item = item
        self.calendar = calendar
        self.files = files
        self.opener = opener
        self.onSave = onSave
        self.onCancel = onCancel
        self.onAddFiles = onAddFiles
        self.onDeleteMaterial = onDeleteMaterial
        let due = item.note.due
        _title = State(initialValue: item.note.title)
        _detail = State(initialValue: item.note.detail)
        _hasDue = State(initialValue: due != nil)
        _includesTime = State(initialValue: due?.time != nil)
        _dueDate = State(initialValue: due?.date(calendar: calendar) ?? calendar.startOfDay(for: Date()))
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Toggle("Due", isOn: $hasDue).toggleStyle(.checkbox)
                if hasDue {
                    DatePicker("", selection: $dueDate, displayedComponents: .date)
                        .labelsHidden()
                        .environment(\.calendar, calendar)
                    Toggle("Time", isOn: $includesTime).toggleStyle(.checkbox)
                    if includesTime {
                        DatePicker("", selection: $dueDate, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .environment(\.calendar, calendar)
                    }
                }
            }
            .font(.system(size: 12))

            TextEditor(text: $detail)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 90, maxHeight: 220)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            ForEach(item.materials) { material in
                MaterialChip(
                    material: material, files: files, opener: opener,
                    onDelete: { onDeleteMaterial(material.id) })
            }

            Text("Drop files here to add them as Material.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            isDropTargeted ? Color.accentColor : Color.primary.opacity(0.15),
                            style: StrokeStyle(lineWidth: 1, dash: [4]))
                )

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Done Editing", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(trimmedTitle.isEmpty)
            }
            .controlSize(.small)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            guard !fileURLs.isEmpty else { return false }
            onAddFiles(fileURLs)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
    }

    private func save() {
        guard !trimmedTitle.isEmpty else { return }
        let due = hasDue ? DueDate(date: dueDate, includesTime: includesTime, calendar: calendar) : nil
        onSave(trimmedTitle, due, detail)
    }
}
