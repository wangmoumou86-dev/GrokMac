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
            if model.place == .chat || model.place == .imagine {
                ChatPane()
            } else {
                PlacesView()
            }
        }
        .inspector(isPresented: Binding(get: { model.cliOpen && (model.place == .chat || model.place == .imagine) }, set: { model.cliOpen = $0 })) {
            CLIPane()
                .inspectorColumnWidth(min: 300, ideal: 380, max: 520)
        }
        .sheet(isPresented: $model.showPalette) {
            PaletteSheet()
        }
        .overlay {
            if model.showLogin {
                LoginGate()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.gateTitle.isEmpty {
                GateBar()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                model.dueAutomation()
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
        let all = ["新对话", "显示终端", "Fast", "Auto", "Expert", "代码模式", "计划模式", "提问模式", "登录"]
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
        case "登录":
            model.showLogin = true
        default: break
        }
        dismiss()
    }
}

private struct LoginGate: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            VStack(spacing: 16) {
                Image("GrokMark")
                    .resizable()
                    .frame(width: 72, height: 72)
                Text("Grok")
                    .font(.system(size: 40, weight: .medium))
                Text("会在浏览器打开 accounts.x.ai")
                    .foregroundStyle(.secondary)
                Button("登录") {
                    LoginSession.start()
                    model.showLogin = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("暂时跳过") {
                    model.showLogin = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(32)
        }
    }
}
