import MarkdownUI
import NotesCore
import SwiftUI

/// 一条 Note（SPEC §2.3）：收起时是勾选、Title、Material 数量和相对日期；点击展开 Detail 和 Material 条。
struct NoteRow: View {
    let item: NoteWithMaterials
    let model: BoardModel
    let opener: any URLOpening
    /// 点击这一行时通知列表拿走键盘焦点，⌫ 才能作用在选中的行上。
    let onActivate: () -> Void

    private var note: Note { item.note }
    private var isDone: Bool { note.doneAt != nil }
    private var isExpanded: Bool { model.state.expandedID == note.id }
    private var isEditing: Bool { model.state.editingID == note.id }
    private var isSelected: Bool { model.state.selectedID == note.id }
    private var isHighlighted: Bool { model.state.highlightedIDs.contains(note.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isExpanded {
                if isEditing { editor } else { details }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
        .animation(.easeOut(duration: 0.6), value: isHighlighted)
        .contextMenu {
            Button("Delete", role: .destructive) { model.delete(note.id) }
        }
    }

    private var background: Color {
        if isHighlighted { return Color.accentColor.opacity(0.25) }
        if isSelected { return Color.primary.opacity(0.08) }
        return .clear
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                model.setDone(note.id, done: !isDone)
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isDone ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            }
            .buttonStyle(.plain)

            Text(note.title)
                .font(.system(size: 13))
                .strikethrough(isDone)
                .foregroundStyle(isDone ? .secondary : .primary)
                .lineLimit(isExpanded ? nil : 1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !item.materials.isEmpty {
                Label("\(item.materials.count)", systemImage: "paperclip")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let due = note.due {
                DueDateLabel(due: due, isDone: isDone, today: model.now, calendar: model.calendar)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onActivate()
            model.toggleExpanded(note.id)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !note.detail.isEmpty {
                Markdown(note.detail)
                    .markdownTheme(.notes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(item.materials) { material in
                MaterialChip(material: material, files: model.files, opener: opener)
            }
            HStack {
                Spacer()
                Button("Edit") { model.beginEditing(note.id) }
                    .controlSize(.small)
            }
        }
        .padding(.leading, 24)
    }

    private var editor: some View {
        NoteEditor(
            item: item, calendar: model.calendar, files: model.files, opener: opener,
            onSave: { title, due, detail in model.save(id: note.id, title: title, due: due, detail: detail) },
            onCancel: { model.endEditing() },
            onAddFiles: { model.addFiles($0, to: note.id) },
            onDeleteMaterial: { model.deleteMaterial($0) }
        )
        .padding(.leading, 24)
    }
}
