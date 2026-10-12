import NotesCore
import SwiftUI

/// Board 的内容（SPEC §2.2）：顶栏、分组列表、空状态。
struct BoardView: View {
    let model: BoardModel
    let opener: any URLOpening
    var onAddNote: () -> Void
    var onClose: () -> Void

    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if model.hasLoaded && model.sections.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(minWidth: 280, minHeight: 240)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Notes")
                .font(.system(size: 14, weight: .semibold))
                .allowsHitTesting(false)
            Spacer()
            Button(action: onAddNote) { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .help("New Note")
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help("Hide Board")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(WindowDragArea())
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checklist").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text("Nothing to do").font(.system(size: 13, weight: .medium))
            Text("Press your Hotkey or click + to add a note.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.sections) { content in
                        sectionHeader(content)
                        if content.section != .done || model.state.isDoneExpanded {
                            ForEach(content.notes) { item in
                                NoteRow(item: item, model: model, opener: opener) { listFocused = true }
                                    .id(item.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.delete) {
                guard model.state.deletableID != nil else { return .ignored }
                model.deleteSelected()
                return .handled
            }
            .onChange(of: model.state.highlightedIDs) { _, highlighted in
                guard let first = model.sections.flatMap(\.notes).first(where: { highlighted.contains($0.id) }) else { return }
                withAnimation { proxy.scrollTo(first.id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ content: BoardSectionContent) -> some View {
        let title = Self.title(for: content.section)
        if content.section == .done {
            Button {
                model.setDoneExpanded(!model.state.isDoneExpanded)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.state.isDoneExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(title)
                    Text("\(content.notes.count)")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sectionHeaderStyle()
        } else {
            Text(title).sectionHeaderStyle()
        }
    }

    static func title(for section: BoardSection) -> LocalizedStringKey {
        switch section {
        case .overdue: "Overdue"
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .noDate: "No Date"
        case .done: "Done"
        }
    }
}

private extension View {
    func sectionHeaderStyle() -> some View {
        self
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }
}
