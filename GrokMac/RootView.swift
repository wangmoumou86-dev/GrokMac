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
        .sheet(isPresented: $model.showPalette) {
            PaletteSheet()
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet()
        }
        .sheet(item: Binding(get: { model.webURL.map(WebTarget.init) }, set: { model.webURL = $0?.url })) { target in
            WebSheet(url: target.url)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return .systemAction }
            model.webURL = url
            return .handled
        })
        .overlay {
            if model.showLogin {
                LoginGate()
            }
        }
        .safeAreaInset(edge: .bottom) {
            // In chat the approval renders inline under its tool card (ChatPane); elsewhere it shows here.
            if !model.gateTitle.isEmpty, model.place != .chat, model.place != .imagine {
                GateBar()
            }
        }
        .task {
            MCPManager.shared.startIfNeeded()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                model.dueAutomation()
            }
        }
    }
}


private struct PaletteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var items: [String] {
        // 登录 only while signed out, so the palette can never start a re-login over a working session.
        let all = ["新对话", "Auto", "Fast", "Expert", "Heavy", "代码模式", "计划模式", "提问模式"] + (model.signedIn ? [] : ["登录"])
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索命令", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.ui(15))
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
        case "Fast": model.tier = .fast
        case "Auto": model.tier = .auto
        case "Expert": model.tier = .expert
        case "Heavy": model.tier = .heavy
        case "代码模式": model.mode = .code
        case "计划模式": model.mode = .plan
        case "提问模式": model.mode = .ask
        case "登录":
            model.beginLogin()
        default: break
        }
        dismiss()
    }
}

private struct LoginGate: View {
    @Environment(AppModel.self) private var model
    @State private var pasted = ""

    var body: some View {
        ZStack {
            Theme.scrim.ignoresSafeArea()
            VStack(spacing: 16) {
                Image("GrokMark")
                    .resizable()
                    .frame(width: 72, height: 72)
                Text("Grok")
                    .font(Theme.ui(40, .medium))
                Text("打开官方授权页，用 X、Google 或 Apple")
                    .foregroundStyle(.secondary)
                Button(model.loginWaiting ? "重新打开授权页" : "登录") {
                    model.beginLogin()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                if model.loginWaiting {
                    Text("授权后如果页面给了一串码，粘贴到这里")
                        .font(Theme.ui(12))
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("授权码", text: $pasted)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 280)
                            .onSubmit(submitCode)
                        Button("提交", action: submitCode)
                            .disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if model.loginFailed {
                        Text("登录没有成功，检查授权码后再提交，或重新打开授权页")
                            .font(Theme.ui(12))
                            .foregroundStyle(.red)
                    }
                }
                Button("暂时跳过") {
                    model.skipLogin()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(32)
        }
    }

    private func submitCode() {
        model.submitLoginCode(pasted)
        pasted = ""
    }
}


private struct WebTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
