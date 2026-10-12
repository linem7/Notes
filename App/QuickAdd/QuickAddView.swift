import AppKit
import NotesCore
import SwiftUI

/// Quick Add 面板的内容：顶栏、输入区、Draft 区（SPEC §3.1）。
struct QuickAddView: View {
    @Bindable var store: QuickAddStore
    let context: QuickAddContext
    let composer: ComposerHandle
    let onPickFiles: () -> Void

    @State private var composerHeight: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            inputArea
            Divider()
            draftArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 文件拖到面板任何地方都作为 File（拖到输入框上的由 ComposerNSTextView 处理）
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            store.addFiles(files)
            return true
        }
    }

    // MARK: 顶栏

    private var header: some View {
        HStack(spacing: 8) {
            Text("Quick Add")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Text(verbatim: context.modelLabel ?? "—")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14))
        .contentShape(Rectangle())
        // 顶栏空当可拖动；按钮不在这里，所以整条都是拖动区
        .gesture(WindowDragGesture())
    }

    // MARK: 输入区

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            ComposerTextView(
                text: $store.inputText,
                contentHeight: $composerHeight,
                handle: composer,
                onSubmit: { store.organize() },
                onSaveCommand: { Task { await store.save() } },
                onAttachFiles: { store.addFiles($0) },
                onAttachImage: { store.addImageData($0) }
            )
            .frame(height: min(max(composerHeight, 40), 150))
            .overlay(alignment: .topLeading) {
                if store.inputText.isEmpty {
                    Text("Paste a chat, drop a file, or type what you need to do")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }

            if !store.items.isEmpty || !store.stageFailures.isEmpty {
                MaterialStrip(
                    items: store.items,
                    failures: store.stageFailures,
                    onRemoveItem: { store.removeItem(id: $0) },
                    onRemoveFailure: { store.removeStageFailure(id: $0) }
                )
            }

            HStack(spacing: 8) {
                Button(action: onPickFiles) {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Add Files")
                Group {
                    if store.drafts.isEmpty {
                        Text("⏎ Organize · ⌘⏎ Save as is · ⇧⏎ New line")
                    } else {
                        Text("⏎ Organize again · ⌘⏎ Save · ⇧⏎ New line")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if store.hasContent {
                    Button("Clear") { store.clear() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
    }

    // MARK: Draft 区

    @ViewBuilder
    private var draftArea: some View {
        switch store.phase {
        case .idle:
            VStack {
                if store.saveFailed { SaveFailedNotice() }
                Spacer()
            }
        case .organizing(let received):
            VStack(spacing: 10) {
                ProgressView()
                Group {
                    if received > 0 {
                        Text("Organizing… \(received) characters")
                    } else {
                        Text("Organizing…")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                Button("Cancel (⌘.)") { store.cancelOrganize() }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let failure):
            failureView(failure)
        case .drafts:
            draftList
        }
    }

    private var draftList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach($store.drafts) { $draft in
                        DraftCard(
                            draft: $draft,
                            materials: store.materials(of: draft),
                            onDetach: { store.detach(materialID: $0, from: draft.id) }
                        )
                    }
                }
                .padding(14)
            }
            Divider()
            HStack {
                if store.saveFailed { SaveFailedNotice() }
                Spacer()
                Button {
                    Task { await store.save() }
                } label: {
                    Text(saveButtonTitle)
                }
                .disabled(!store.canSave)
                .controlSize(.large)
            }
            .padding(EdgeInsets(top: 8, leading: 14, bottom: 10, trailing: 14))
        }
    }

    private var saveButtonTitle: LocalizedStringKey {
        let count = store.drafts.filter(\.isSelected).count
        return count == 1 ? "Save 1 Note (⌘⏎)" : "Save \(count) Notes (⌘⏎)"
    }

    private func failureView(_ failure: QuickAddStore.Failure) -> some View {
        VStack(spacing: 10) {
            switch failure {
            case .noConnection:
                Text("Add a Connection first to let the model organize your notes.")
                    .multilineTextAlignment(.center)
                Button("Open Settings…") { context.openSettings() }
                Text("You can still save the input as is with ⌘⏎.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .chat(let error):
                Text(verbatim: error.displayText)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                HStack {
                    if error.offersOpenSettings {
                        Button("Open Settings…") { context.openSettings() }
                    }
                    Button("Retry") { store.organize() }
                }
            }
            if store.saveFailed { SaveFailedNotice() }
        }
        .font(.system(size: 12))
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SaveFailedNotice: View {
    var body: some View {
        Text("Couldn't save")
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .padding(.horizontal, 14)
            .padding(.top, 8)
    }
}
