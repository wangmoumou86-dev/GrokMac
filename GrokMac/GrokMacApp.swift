import SwiftUI

@main
struct GrokMacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(Prefs.shared.colorScheme)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { GrokCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(Prefs.shared.colorScheme)
        }
    }
}

private struct GrokCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新对话") { model.newSession() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("会话") {
            Button("命令面板") { model.showPalette = true }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            modeButton("代码", .code)
            modeButton("计划", .plan)
            modeButton("提问", .ask)
            Divider()
            ForEach(ReplyTier.allCases) { tier in
                tierButton("\(tier.title) · \(tier.hint)", tier)
            }
        }
    }

    private func modeButton(_ title: String, _ mode: AgentMode) -> some View {
        Button(title) { model.mode = mode }
            .disabled(model.mode == mode)
    }

    private func tierButton(_ title: String, _ tier: ReplyTier) -> some View {
        Button(title) { model.tier = tier }
            .disabled(model.tier == tier)
    }
}
