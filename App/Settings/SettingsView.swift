import AppKit
import KeyboardShortcuts
import NotesCore
import SwiftUI

/// 设置窗口，三个标签页：General、Connection、Advanced（SPEC §7）。
struct SettingsView: View {
    let services: AppServices

    var body: some View {
        TabView(selection: Bindable(services.navigation).tab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsView(services: services)
            }
            Tab("Connection", systemImage: "network", value: SettingsTab.connections) {
                ConnectionsSettingsView(
                    connections: services.connections, apiKeys: services.apiKeys, navigation: services.navigation
                )
            }
            Tab("Advanced", systemImage: "slider.horizontal.3", value: SettingsTab.advanced) {
                AdvancedSettingsView(services: services)
            }
        }
        .frame(width: 680, height: 500)
        .regularWindow(.settings)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    let services: AppServices
    @State private var language = AppLanguage.stored()
    @State private var relaunchFailed = false
    @State private var shortcut = KeyboardShortcuts.getShortcut(for: .quickAdd)

    private var launchAtLogin: LaunchAtLogin { services.launchAtLogin }

    var body: some View {
        Form {
            Section {
                LabeledContent("Hotkey") {
                    KeyboardShortcuts.Recorder(for: .quickAdd) { shortcut = $0 }
                }
                Text(Hotkey.otherAppsHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // 只有 option 的组合（默认 option+N）在美式键盘上本来是输入特殊字符，比如 ñ（SPEC §3.1）
                if let shortcut, shortcut.modifiers == [.option] {
                    Text("On a US keyboard, \(shortcut.description) normally types a special character such as ñ. While it is the Hotkey, it no longer types.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Language", selection: $language) {
                    Text(verbatim: "English").tag(AppLanguage.english)
                    Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                }
                .onChange(of: language) { _, newValue in newValue.select() }
                if language != services.launchLanguage {
                    HStack {
                        Text("Relaunch Notes to switch the language.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch") {
                            Task {
                                relaunchFailed = !(await Relauncher.relaunch())
                            }
                        }
                    }
                    if relaunchFailed {
                        Text("Couldn't relaunch Notes. Quit and open it again to switch the language.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                Picker("Board Mode", selection: Bindable(services.board).mode) {
                    Text("On Desktop").tag(BoardMode.onDesktop)
                    Text("On Top").tag(BoardMode.onTop)
                }
                Text("On Desktop keeps the Board behind other windows, like Stickies. On Top keeps it above them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLogin.isEnabled || launchAtLogin.requiresApproval },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if launchAtLogin.requiresApproval {
                    HStack {
                        Text("Allow Notes in System Settings › General › Login Items & Extensions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { launchAtLogin.openSystemSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        // 用户可能刚在 System Settings 里改了登录项，设置窗一露面就重看一次
        .onAppear { launchAtLogin.refresh() }
    }
}

/// 启动一个新实例，成功后再退出自己（SPEC §6）。新实例没启动成功时不退出，返回 false。
@MainActor
enum Relauncher {
    static func relaunch() async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        } catch {
            return false
        }
        NSApp.terminate(nil)
        return true
    }
}

// MARK: - Advanced

private struct AdvancedSettingsView: View {
    let services: AppServices
    @State private var prompt = ""
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var failureMessage: String?

    var body: some View {
        Form {
            Section("Organize Prompt") {
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 160)
                    .onChange(of: prompt) { _, newValue in save(newValue) }
                HStack {
                    Text("Today's date and time zone are added at the start automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Default") {
                        OrganizePromptSetting.restoreDefault()
                        prompt = OrganizePromptDefaults.text
                    }
                    .disabled(prompt == OrganizePromptDefaults.text)
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Data Folder")
                        Text("Notes and their Materials are stored on this Mac only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show in Finder") { showDataFolder() }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete All Done Notes")
                        Text("Deletes every completed Note and its Materials.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let failureMessage {
                            Text(verbatim: failureMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    if isDeleting { ProgressView().controlSize(.small) }
                    Button("Delete…", role: .destructive) { isConfirmingDelete = true }
                        .disabled(isDeleting || services.noteStore == nil)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { prompt = OrganizePromptSetting.text(defaultText: OrganizePromptDefaults.text) }
        // 删除所有已完成的 Note 要二次确认（SPEC §7）
        .confirmationDialog("Delete all done Notes?", isPresented: $isConfirmingDelete) {
            Button("Delete All Done Notes", role: .destructive) { deleteAllDone() }
        } message: {
            Text("All completed Notes and their Materials will be deleted. This can't be undone.")
        }
    }

    /// 和默认文本一样就不存，这样默认文本以后更新时没改过的用户能跟着更新。
    /// 清空了就恢复成默认文本，免得编辑框是空的、实际用的却是默认 prompt。
    private func save(_ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            OrganizePromptSetting.restoreDefault()
            prompt = OrganizePromptDefaults.text
        } else if text == OrganizePromptDefaults.text {
            OrganizePromptSetting.restoreDefault()
        } else {
            UserDefaults.standard.set(text, forKey: OrganizePromptSetting.defaultsKey)
        }
    }

    private func showDataFolder() {
        let directory = AppDelegate.dataDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    private func deleteAllDone() {
        guard let store = services.noteStore else { return }
        isDeleting = true
        failureMessage = nil
        Task {
            do {
                try await store.deleteAllDone()
            } catch {
                failureMessage = String(localized: "Couldn't delete the Notes.")
            }
            isDeleting = false
        }
    }
}

/// 设置页取默认 Organize prompt 的唯一入口。
enum OrganizePromptDefaults {
    static var text: String { OrganizePrompt.default }
}
