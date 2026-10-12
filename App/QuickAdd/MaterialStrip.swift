import NotesCore
import SwiftUI

/// 输入框下面的 Material 条：每个 File 和识别到的链接一个小块，带进度 / 警告和 ×（SPEC §3.1、§3.2）。
struct MaterialStrip: View {
    let items: [QuickAddStore.Item]
    let failures: [QuickAddStore.StageFailure]
    let onRemoveItem: (UUID) -> Void
    let onRemoveFailure: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    StagedChip(
                        icon: item.staged.kind == .webPage ? "globe" : "doc",
                        title: item.staged.displayName,
                        status: status(of: item.state),
                        onRemove: { onRemoveItem(item.id) }
                    )
                }
                ForEach(failures) { failure in
                    StagedChip(
                        icon: "doc",
                        title: failure.name,
                        status: .warning(String(localized: "Couldn't add this file.")),
                        onRemove: { onRemoveFailure(failure.id) }
                    )
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func status(of state: ReadableTextState) -> StagedChip.Status {
        switch state {
        case .pending: .preparing
        case .ready: .ready
        case .unavailable(let reason): .warning(reason.hoverText)
        }
    }
}

/// Quick Add 里的一个 Material 小块（Board 里的 `StagedChip` 是另一个，展示已保存的 Material）。
struct StagedChip: View {
    enum Status: Equatable {
        case preparing
        case ready
        case warning(String)
    }

    let icon: String
    let title: String
    let status: Status
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(verbatim: title)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)
            switch status {
            case .preparing:
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
            case .ready:
                EmptyView()
            case .warning(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help(message)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}
