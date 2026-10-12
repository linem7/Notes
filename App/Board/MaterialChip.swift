import NotesCore
import SwiftUI

/// Material 的一个小条（SPEC §2.3）：File 点击打开副本；Web Page 点击打开 URL，旁边有快照和正文按钮；
/// Source 点击在行内展开原文。可以删除时右侧有 ×（编辑中）。
struct MaterialChip: View {
    let material: NotesCore.Material
    let files: MaterialFiles
    let opener: any URLOpening
    var onDelete: (() -> Void)?

    @State private var isTextShown = false
    @State private var text: String?

    private var actions: MaterialActions { MaterialActions(material: material, files: files) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: primaryAction) {
                    HStack(spacing: 5) {
                        Image(systemName: icon).foregroundStyle(.secondary)
                        Text(title).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isPrimaryDisabled)

                Spacer(minLength: 4)

                if material.kind == .webPage {
                    if let snapshot = actions.snapshot {
                        iconButton("doc.richtext", help: "Open PDF snapshot") { opener.open(snapshot) }
                    }
                    if actions.inlineText != nil {
                        iconButton("text.alignleft", help: isTextShown ? "Hide text" : "Show text") { toggleText() }
                    }
                }
                if let onDelete {
                    iconButton("xmark", help: "Remove") { onDelete() }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            if isTextShown {
                ScrollView {
                    Text(text ?? "")
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var title: String {
        material.kind == .source ? String(localized: "Source") : material.displayName
    }

    private var icon: String {
        switch material.kind {
        case .source: "text.quote"
        case .file: "doc"
        case .webPage: "link"
        }
    }

    private var isPrimaryDisabled: Bool {
        actions.primary == nil && !actions.primaryTogglesInlineText
    }

    private func primaryAction() {
        if actions.primaryTogglesInlineText {
            toggleText()
        } else if let url = actions.primary {
            opener.open(url)
        }
    }

    private func toggleText() {
        isTextShown.toggle()
        guard isTextShown, text == nil, let role = actions.inlineText else { return }
        text = (try? files.readText(of: material, role: role)) ?? String(localized: "Couldn't read this file.")
    }

    private func iconButton(_ name: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
