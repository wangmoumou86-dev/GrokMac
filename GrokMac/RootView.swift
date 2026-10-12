import AppKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
        } detail: {
            ChatPane()
        }
        .inspector(isPresented: $model.cliOpen) {
            CLIPane()
                .inspectorColumnWidth(min: 300, ideal: 380, max: 520)
        }
        .sheet(isPresented: $model.showPalette) {
            PaletteSheet()
        }
        .sheet(isPresented: $model.needsKey) {
            KeyPrompt()
        }
        .safeAreaInset(edge: .bottom) {
            if !model.gateTitle.isEmpty {
                GateBar()
            }
        }
    }
}

private struct GateBar: View {
    @Environment(AppModel.self) private var model
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.gateTitle).font(.headline)
            Text(model.gateDetail)
                .font(.caption.monospaced())
                .lineLimit(8)
                .textSelection(.enabled)
            if model.gateKind == "ask" {
                TextField("回答", text: $answer)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("跳过") { model.decide("no") }
                    Button("回答") { model.decide(answer) }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack {
                    Button("拒绝") { model.decide("no") }
                    Button("允许") { model.decide("yes") }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

private struct PaletteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var items: [String] {
        let all = ["新对话", "显示终端", "Fast", "Auto", "Expert", "代码模式", "计划模式", "提问模式", "设置 API Key"]
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索命令", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding()
            Divider()
            List(items, id: \.self) { item in
                Button(item) { run(item) }
                    .buttonStyle(.plain)
            }
            .frame(height: 280)
        }
        .frame(width: 420)
    }

    private func run(_ item: String) {
        switch item {
        case "新对话": model.newSession()
        case "显示终端": model.cliOpen = true
        case "Fast": model.tier = .fast
        case "Auto": model.tier = .auto
        case "Expert": model.tier = .expert
        case "代码模式": model.mode = .code
        case "计划模式": model.mode = .plan
        case "提问模式": model.mode = .ask
        case "设置 API Key":
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        default: break
        }
        dismiss()
    }
}

private struct KeyPrompt: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接 Grok")
                .font(.title2)
            Text("把你自己的 xAI API Key 存在这台 Mac 的钥匙串里。它不会写进工程，也不会上传到别处。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("xai-…", text: $key)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("稍后") { dismiss() }
                Button("保存") {
                    KeychainStore.save(key)
                    model.needsKey = KeychainStore.load().isEmpty
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
