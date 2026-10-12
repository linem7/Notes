import NotesCore
import SwiftUI

/// Connection 页：上面是 Default Model，下面左边是 Connection 列表和「+」模板菜单，右边编辑选中的 Connection（SPEC §7）。
/// 移植自 Chatbot，只留 OpenAI 兼容协议的四个模板。
struct ConnectionsSettingsView: View {
    @Bindable var connections: ConnectionStore
    let apiKeys: APIKeyStore
    @Bindable var navigation: SettingsNavigation

    @State private var selection: UUID?
    /// 正在编辑的 Connection。新建的在保存之前只存在这里。
    @State private var draft: ConnectionDraft?

    var body: some View {
        VStack(spacing: 0) {
            defaultModelRow
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(connections.connections) { connection in
                            Text(verbatim: connection.name).tag(connection.id)
                        }
                        if let draft, draft.isNew {
                            Text(verbatim: draft.name).italic().tag(draft.id)
                        }
                    }
                    Divider()
                    HStack {
                        Menu {
                            ForEach(ConnectionTemplate.allCases) { template in
                                Button(template.title) { startNew(from: template) }
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Add Connection")
                        Spacer()
                    }
                    .padding(8)
                }
                .frame(width: 190)

                Divider()

                if let binding = Binding($draft) {
                    ConnectionEditor(draft: binding, connections: connections, apiKeys: apiKeys) { savedID in
                        selection = savedID
                    } onDeleted: {
                        draft = nil
                        selection = connections.connections.first?.id
                    }
                    .id(binding.wrappedValue.id)
                } else {
                    ContentUnavailableView {
                        Label("No Connection", systemImage: "network")
                    } description: {
                        Text("Add a Connection with the + button, then paste your API key.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear {
            applyPendingTemplate()
            applyPendingConnection()
            if selection == nil, draft == nil { selection = connections.connections.first?.id }
        }
        .onChange(of: navigation.pendingTemplate) { applyPendingTemplate() }
        .onChange(of: navigation.pendingConnectionID) { applyPendingConnection() }
        .onChange(of: selection) { loadDraft(for: selection) }
    }

    private var defaultModelRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Default Model", selection: $connections.defaultModel) {
                Text("None").tag(ModelRef?.none)
                ForEach(connections.connections) { connection in
                    ForEach(connections.visibleModels(of: connection)) { model in
                        Text(verbatim: "\(connection.name) / \(model.displayName ?? model.id)")
                            .tag(Optional(ModelRef(connectionID: connection.id, modelID: model.id)))
                    }
                }
            }
            .disabled(connections.connections.isEmpty)
            if connections.defaultModel == nil, !connections.connections.isEmpty {
                // Default Model 所在的 Connection 或它自己被删掉之后，要求用户重新选
                Text("Choose a Default Model for Organize.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func startNew(from template: ConnectionTemplate) {
        let newDraft = ConnectionDraft(template: template, name: template.title)
        draft = newDraft
        selection = newDraft.id
    }

    /// 首次启动或从 Quick Add 点「添加 Connection」：预选模板（SPEC §8）。
    private func applyPendingTemplate() {
        guard let template = navigation.pendingTemplate else { return }
        navigation.pendingTemplate = nil
        startNew(from: template)
    }

    /// 从错误旁边的「打开设置」过来：选中那个 Connection。
    private func applyPendingConnection() {
        guard let connectionID = navigation.pendingConnectionID else { return }
        navigation.pendingConnectionID = nil
        if connections.connection(id: connectionID) != nil { selection = connectionID }
    }

    private func loadDraft(for id: UUID?) {
        guard let id else {
            draft = nil
            return
        }
        if draft?.id == id { return }
        draft = connections.connection(id: id).map {
            ConnectionDraft(connection: $0, manualModelIDs: connections.manualModelIDs(of: $0.id))
        }
    }
}

private struct ConnectionEditor: View {
    @Binding var draft: ConnectionDraft
    let connections: ConnectionStore
    let apiKeys: APIKeyStore
    let onSaved: (UUID) -> Void
    let onDeleted: () -> Void

    @State private var isSaving = false
    @State private var errorMessage: String?
    /// 拉取 Model 列表失败之后，允许不测试直接保存，再手动填写模型 ID。
    @State private var canSaveWithoutTesting = false
    @State private var manualModelID = ""
    @State private var isConfirmingDelete = false
    /// Keychain 里是否已经有这个 Connection 的 key。出现时读一次，保存新 key 后更新，不在每次重绘时查 Keychain。
    @State private var hasSavedKey = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                TextField("Base URL", text: $draft.baseURL, prompt: Text(verbatim: "https://"))
                // 百炼按地域分端点，模板默认北京；已经在新加坡端点上就不用提示了
                if URL(string: draft.baseURL)?.host() == "dashscope.aliyuncs.com" {
                    Text("For the Singapore region, change the host to dashscope-intl.aliyuncs.com.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SecureField(
                    "API Key",
                    text: $draft.apiKey,
                    prompt: Text(hasSavedKey && !draft.requiresNewKey ? LocalizedStringKey("Saved — paste a new key to replace it") : "Paste your API key")
                )
                HStack {
                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if isSaving { ProgressView().controlSize(.small) }
                    if canSaveWithoutTesting {
                        Button("Save Without Testing") { Task { await save(testing: false) } }
                            .disabled(isSaving)
                    }
                    Button("Save") { Task { await save(testing: true) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSaving)
                }
            } footer: {
                Text("Saving fetches the model list, which also tests the connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Models") {
                if draft.models.isEmpty {
                    Text("No models yet. Save to fetch them, or add a model ID below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(draft.models) { model in
                    HStack {
                        Toggle(isOn: visibility(of: model.id)) {
                            Text(verbatim: model.displayName ?? model.id)
                        }
                        // 只有手动填写的可以删掉；拉取到的用勾选来隐藏
                        if draft.manualModelIDs.contains(model.id) {
                            Button {
                                removeManualModel(model.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                    }
                }
                HStack {
                    TextField("Model ID", text: $manualModelID, prompt: Text("Add a model ID manually"))
                    Button("Add") { addManualModel() }
                        .disabled(manualModelID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if !draft.isNew {
                Section {
                    Button("Delete Connection…", role: .destructive) { isConfirmingDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hasSavedKey = !draft.isNew && ((try? apiKeys.apiKey(for: draft.id)) ?? nil) != nil
        }
        .confirmationDialog("Delete Connection?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) { delete() }
        } message: {
            Text("The Connection and its API key will be removed from this Mac. This can't be undone.")
        }
    }

    /// 勾选表示在 Default Model 选择器里显示。已经保存过的 Connection 立即生效，不用再按保存。
    private func visibility(of modelID: String) -> Binding<Bool> {
        Binding {
            !draft.hiddenModelIDs.contains(modelID)
        } set: { isVisible in
            if isVisible { draft.hiddenModelIDs.remove(modelID) } else { draft.hiddenModelIDs.insert(modelID) }
            guard !draft.isNew, var stored = connections.connection(id: draft.id) else { return }
            stored.hiddenModelIDs = draft.hiddenModelIDs
            connections.save(stored)
            clearDefaultModelIfHidden(modelID)
        }
    }

    /// 隐藏的正好是 Default Model：清空，由用户在上面重新选。
    private func clearDefaultModelIfHidden(_ modelID: String) {
        if draft.hiddenModelIDs.contains(modelID),
           connections.defaultModel == ModelRef(connectionID: draft.id, modelID: modelID) {
            connections.defaultModel = nil
        }
    }

    /// 手动填写模型 ID（SPEC §4）：拉取失败时，或者 `/models` 返回的列表不全时用。已经保存过的 Connection 立即生效。
    private func addManualModel() {
        let id = manualModelID.trimmingCharacters(in: .whitespaces)
        manualModelID = ""
        guard !draft.models.contains(where: { $0.id == id }) else { return }
        draft.models.append(ModelInfo(id: id))
        draft.manualModelIDs.append(id)
        persistModelsIfSaved()
    }

    private func removeManualModel(_ id: String) {
        draft.models.removeAll { $0.id == id }
        draft.manualModelIDs.removeAll { $0 == id }
        persistModelsIfSaved()
        // 删掉的正好是 Default Model：清空，由用户重新选
        if !draft.isNew, connections.defaultModel == ModelRef(connectionID: draft.id, modelID: id) {
            connections.defaultModel = nil
        }
    }

    private func persistModelsIfSaved() {
        guard !draft.isNew, var stored = connections.connection(id: draft.id) else { return }
        stored.models = draft.models
        connections.save(stored)
        connections.setManualModelIDs(draft.manualModelIDs, of: draft.id)
    }

    /// 保存时拉取 Model 列表，这一步同时就是连接测试；成功才写进 Keychain（SPEC §4）。
    private func save(testing: Bool) async {
        errorMessage = nil
        guard var connection = draft.makeConnection() else {
            errorMessage = String(localized: "Enter a valid base URL, such as https://…")
            return
        }
        let newKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedKey = draft.isNew ? nil : (try? apiKeys.apiKey(for: connection.id)) ?? nil
        // base URL 的来源变了就不沿用已保存的 key，免得把它发到别的服务器
        guard let key = draft.effectiveKey(pasted: newKey, saved: savedKey) else {
            errorMessage = draft.requiresNewKey && !draft.isNew
                ? String(localized: "The base URL changed. Paste the API key again.")
                : String(localized: "Paste an API key.")
            return
        }

        isSaving = true
        defer { isSaving = false }
        var manualModelIDs = draft.manualModelIDs
        if testing {
            do {
                let fetched = try await OpenAICompatibleClient().listModels(connection: connection, apiKey: key)
                let merged = draft.merging(fetched: fetched)
                connection.models = merged.models
                manualModelIDs = merged.manualModelIDs
            } catch {
                errorMessage = (error as? ChatError)?.displayText ?? error.localizedDescription
                canSaveWithoutTesting = true
                return
            }
        }
        if !newKey.isEmpty {
            do {
                try apiKeys.setAPIKey(newKey, for: connection.id)
            } catch {
                errorMessage = String(localized: "Couldn't save the API key to the Keychain.")
                return
            }
        }
        connections.save(connection)
        connections.setManualModelIDs(manualModelIDs, of: connection.id)
        canSaveWithoutTesting = false
        if !newKey.isEmpty { hasSavedKey = true }
        draft = ConnectionDraft(connection: connection, manualModelIDs: manualModelIDs)
        onSaved(connection.id)
    }

    /// 删除 Connection：先删 key，再删 Connection 本身。
    private func delete() {
        try? apiKeys.deleteAPIKey(for: draft.id)
        connections.delete(draft.id)
        onDeleted()
    }
}
