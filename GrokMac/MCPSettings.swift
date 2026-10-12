import SwiftUI

/// Settings → MCP 服务器: add, edit, enable, see status and tool count, reconnect.
struct MCPSettings: View {
    @State private var manager = MCPManager.shared
    @State private var editing: MCPServerConfig?
    @State private var editingOriginal: String?
    @State private var importText = ""
    @State private var importStatus = ""

    var body: some View {
        Form {
            Section(tr("MCP 服务器", "MCP servers")) {
                if manager.servers.isEmpty {
                    Text(tr("还没有服务器。添加后，它的工具会出现在对话里（代码模式）。", "No servers yet. Their tools show up in chat (Code mode)."))
                        .font(Theme.ui(12)).foregroundStyle(.secondary)
                }
                ForEach(manager.servers) { server in
                    row(server)
                }
                HStack {
                    Button(tr("添加服务器…", "Add server…")) {
                        editingOriginal = nil
                        editing = MCPServerConfig(name: "")
                    }
                    Spacer()
                    Button(tr("全部重连", "Reconnect all")) { manager.load(); manager.connectAll() }
                }
            }
            Section(tr("从 JSON 导入", "Import JSON")) {
                TextEditor(text: $importText)
                    .font(Theme.mono(11))
                    .frame(height: 70)
                HStack {
                    Text(tr("粘贴 Claude/Cursor 格式的 {\"mcpServers\": {…}}", "Paste a Claude/Cursor {\"mcpServers\": {…}} block"))
                        .font(Theme.ui(11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("导入", "Import")) { importJSON() }.disabled(importText.isEmpty)
                }
                if !importStatus.isEmpty { Text(importStatus).font(Theme.ui(11)) }
            }
            Section {
                Text(tr("配置文件：", "Config file: ") + MCPManager.fileURL.path)
                    .font(Theme.ui(11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .warmForm()
        .sheet(item: $editing) { server in
            MCPServerEditor(server: server) { saved in
                if let saved { manager.upsert(saved, replacing: editingOriginal) }
                editing = nil
            }
        }
    }

    private func row(_ server: MCPServerConfig) -> some View {
        let state = manager.status[server.name] ?? (server.enabled ? "connecting" : "off")
        let count = manager.tools[server.name]?.count ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(color(state)).frame(width: 8, height: 8)
                Text(server.name).font(Theme.ui(13, .medium))
                Text(label(state, count)).font(Theme.ui(11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Toggle("", isOn: Binding(get: { server.enabled }, set: { manager.setEnabled(server.name, $0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            Text(server.isHTTP ? server.url : ([server.command] + server.args).joined(separator: " "))
                .font(Theme.mono(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 10) {
                Button(tr("重连", "Reconnect")) { manager.connect(server.name) }.disabled(!server.enabled)
                Button(tr("编辑", "Edit")) { editingOriginal = server.name; editing = server }
                Toggle(tr("始终允许", "Always allow"), isOn: Binding(get: { server.alwaysAllow }, set: { manager.setAlwaysAllow(server.name, $0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button(tr("删除", "Remove"), role: .destructive) { manager.remove(server.name) }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func color(_ state: String) -> Color {
        state == "connected" ? .green : state.hasPrefix("error") ? .red : state == "off" ? .gray : .orange
    }

    private func label(_ state: String, _ count: Int) -> String {
        if state == "connected" { return tr("已连接 · \(count) 个工具", "Connected · \(count) tools") }
        if state == "off" { return tr("已停用", "Off") }
        if state.hasPrefix("error: ") { return tr("出错：", "Error: ") + state.dropFirst(7) }
        return tr("连接中…", "Connecting…")
    }

    private func importJSON() {
        guard let json = try? JSONSerialization.jsonObject(with: Data(importText.utf8)) as? [String: Any] else {
            importStatus = tr("不是有效的 JSON。", "Not valid JSON."); return
        }
        let map = (json["mcpServers"] as? [String: [String: Any]]) ?? (json as? [String: [String: Any]]) ?? [:]
        var added = 0
        for (name, raw) in map {
            let server = MCPServerConfig(
                name: name,
                command: raw["command"] as? String ?? "",
                args: raw["args"] as? [String] ?? [],
                env: raw["env"] as? [String: String] ?? [:],
                url: raw["url"] as? String ?? "",
                headers: raw["headers"] as? [String: String] ?? [:])
            guard !server.command.isEmpty || !server.url.isEmpty else { continue }
            manager.upsert(server, replacing: nil)
            added += 1
        }
        importStatus = added == 0 ? tr("没有找到服务器。", "No servers found.") : tr("已导入 \(added) 个。", "Imported \(added).")
        if added > 0 { importText = "" }
    }
}

private struct MCPServerEditor: View {
    @State var server: MCPServerConfig
    var done: (MCPServerConfig?) -> Void
    @State private var http = false
    @State private var argsText = ""
    @State private var envText = ""

    init(server: MCPServerConfig, done: @escaping (MCPServerConfig?) -> Void) {
        _server = State(initialValue: server)
        self.done = done
        _http = State(initialValue: server.isHTTP)
        _argsText = State(initialValue: server.args.joined(separator: "\n"))
        _envText = State(initialValue: (server.isHTTP ? server.headers : server.env).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField(tr("名称", "Name"), text: $server.name)
                Picker(tr("类型", "Type"), selection: $http) {
                    Text(tr("本地命令 (stdio)", "Local command (stdio)")).tag(false)
                    Text("HTTP").tag(true)
                }
                if http {
                    TextField("URL", text: $server.url)
                } else {
                    TextField(tr("命令", "Command"), text: $server.command, prompt: Text("npx"))
                    LabeledContent(tr("参数（每行一个）", "Arguments (one per line)")) {
                        TextEditor(text: $argsText).font(Theme.mono(11)).frame(height: 60)
                    }
                }
                LabeledContent(http ? tr("请求头 KEY=VALUE", "Headers KEY=VALUE") : tr("环境变量 KEY=VALUE", "Env KEY=VALUE")) {
                    TextEditor(text: $envText).font(Theme.mono(11)).frame(height: 48)
                }
            }
            .warmForm()
            HStack {
                Spacer()
                Button(tr("取消", "Cancel")) { done(nil) }.keyboardShortcut(.cancelAction)
                Button(tr("保存并连接", "Save & connect")) { done(result()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(server.name.trimmingCharacters(in: .whitespaces).isEmpty || (http ? server.url.isEmpty : server.command.isEmpty))
            }
            .padding(12)
        }
        .frame(width: 480, height: 400)
        .background(Theme.base)
    }

    private func result() -> MCPServerConfig {
        var out = server
        out.name = server.name.trimmingCharacters(in: .whitespaces)
        var pairs: [String: String] = [:]
        for line in envText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { pairs[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1] }
        }
        if http {
            out.command = ""; out.args = []; out.env = [:]; out.headers = pairs
        } else {
            out.url = ""; out.headers = [:]; out.env = pairs
            out.args = argsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return out
    }
}
