import SwiftUI

@main
struct GrokMacApp: App {
    @State private var model = AppModel()

    init() {
        Theme.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .font(Theme.ui(13))
                .environment(model)
                .preferredColorScheme(Prefs.shared.colorScheme)
        }
        .defaultSize(width: 1180, height: 760)
        .commands { GrokCommands(model: model) }
    }
}

private struct GrokCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(tr("设置…", "Settings…")) { model.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button(tr("新对话", "New chat")) { model.newSession() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu(tr("会话", "Session")) {
            Button(tr("命令面板", "Command Palette")) { model.showPalette = true }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            modeButton(tr("代码", "Code"), .code)
            modeButton(tr("计划", "Plan"), .plan)
            modeButton(tr("提问", "Ask"), .ask)
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
