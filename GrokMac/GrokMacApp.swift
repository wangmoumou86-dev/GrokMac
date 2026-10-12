import SwiftUI

@main
struct GrokMacApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { GrokCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
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
        CommandGroup(after: .sidebar) {
            Button("终端") { model.cliOpen.toggle() }
                .keyboardShortcut("j", modifiers: .command)
        }
        CommandMenu("会话") {
            Button("命令面板") { model.showPalette = true }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            modeButton("代码", .code)
            modeButton("计划", .plan)
            modeButton("提问", .ask)
            Divider()
            tierButton("Fast", .fast)
            tierButton("Auto", .auto)
            tierButton("Expert", .expert)
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
