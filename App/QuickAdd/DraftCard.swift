import NotesCore
import SwiftUI

/// 一条 Draft 的可编辑卡片：勾选、Title、Due Date、Detail、挂着的 Material（SPEC §3.3）。
struct DraftCard: View {
    @Binding var draft: Draft
    let materials: [StagedMaterial]
    let onDetach: (UUID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: $draft.isSelected) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(.top, 2)
                .help("Save this note")

            VStack(alignment: .leading, spacing: 8) {
                TextField("Title", text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))

                DueDateRow(due: $draft.due)

                TextField("Detail", text: $draft.detail, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...8)

                if !materials.isEmpty {
                    FlowChips(materials: materials, onDetach: onDetach)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(draft.isSelected ? 0.5 : 0.2), in: RoundedRectangle(cornerRadius: 10))
        .opacity(draft.isSelected ? 1 : 0.6)
    }
}

private struct FlowChips: View {
    let materials: [StagedMaterial]
    let onDetach: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(materials) { material in
                    StagedChip(
                        icon: material.kind == .webPage ? "globe" : "doc",
                        title: material.displayName,
                        status: .ready,
                        onRemove: { onDetach(material.id) }
                    )
                }
            }
        }
    }
}

/// Due Date：没有时显示「Add Due Date」，有时是日期选择器加可选的时间，可以清除。
private struct DueDateRow: View {
    @Binding var due: DueDate?

    var body: some View {
        if let current = due {
            HStack(spacing: 8) {
                DatePicker("Due", selection: dayBinding(current), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                if current.time != nil {
                    DatePicker("Time", selection: timeBinding(current), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                    Button("Remove Time") { due?.time = nil }
                        .buttonStyle(.link)
                } else {
                    Button("Add Time") { due?.time = "09:00" }
                        .buttonStyle(.link)
                }
                Button {
                    due = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Due Date")
            }
            .font(.system(size: 12))
        } else {
            Button("Add Due Date") { due = DueDate(day: DueDateFormat.day.string(from: Date())) }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
    }

    private func dayBinding(_ current: DueDate) -> Binding<Date> {
        Binding(
            get: { DueDateFormat.day.date(from: current.day) ?? Date() },
            set: { due?.day = DueDateFormat.day.string(from: $0) }
        )
    }

    private func timeBinding(_ current: DueDate) -> Binding<Date> {
        Binding(
            get: { current.time.flatMap { DueDateFormat.time.date(from: $0) } ?? Date() },
            set: { due?.time = DueDateFormat.time.string(from: $0) }
        )
    }
}

/// DueDate 的 "yyyy-MM-dd" / "HH:mm" 和 Date 互转，按本地日历和时区（不随时区漂移）。
private enum DueDateFormat {
    static let day = make("yyyy-MM-dd")
    static let time = make("HH:mm")

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }
}
