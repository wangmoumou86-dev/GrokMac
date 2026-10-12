import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            Button { model.newSession() } label: {
                SidebarRow(title: tr("新建对话", "New chat"), symbol: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .help(tr("新对话 (⌘N)", "New chat (⌘N)"))
            .padding(.horizontal, 8)
            .padding(.top, 6)
            List {
                Section {
                    placeButton(.chat, "bubble.left")
                    placeButton(.imagine, "photo")
                    placeButton(.library, "rectangle.stack")
                    placeButton(.automations, "bolt.badge.clock")
                }
                Section {
                    HStack {
                        Button {
                            model.botsOpen.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Text(tr("机器人", "Bots"))
                                Image(systemName: model.botsOpen ? "chevron.down" : "chevron.right")
                                    .font(Theme.ui(10, .semibold))
                                    .foregroundStyle(Theme.fg3)
                            }
                            .font(Theme.ui(15))
                            .foregroundStyle(Theme.sidebarFg)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button {
                            model.place = .hub
                            model.hubTab = "bots"
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                    }
                    if model.botsOpen {
                        if model.bots.isEmpty {
                            Text(tr("还没有 Bot", "No bots yet")).foregroundStyle(.secondary)
                        }
                        ForEach(model.bots) { bot in
                            Button {
                                model.activeBotID = bot.id
                                model.place = .chat
                            } label: {
                                SidebarRow(title: bot.name, selected: model.activeBotID == bot.id && model.place == .chat)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            Button {
                                model.select(session.id)
                            } label: {
                                SidebarRow(title: session.title, selected: session.id == model.activeID && model.place == .chat)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(tr("删除", "Delete"), role: .destructive) { model.remove(session.id) }
                            }
                        }
                    } header: {
                        Text(group.title)
                            .font(Theme.ui(15))
                            .foregroundStyle(Theme.sidebarFg)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 36)
            .searchable(text: $query, placement: .sidebar, prompt: tr("搜索", "Search"))
            VStack(spacing: 2) {
                Button {
                    model.place = .hub
                    model.hubTab = "connectors"
                } label: {
                    SidebarRow(title: tr("连接器", "Connectors"), symbol: "link")
                }
                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: {
                    SidebarRow(title: tr("设置", "Settings"), symbol: "gearshape")
                }
                if model.signedIn {
                    Menu {
                        Button(tr("重新登录", "Sign in again")) { model.beginLogin() }
                        Button(tr("退出登录", "Sign out"), role: .destructive) { model.signOut() }
                    } label: {
                        AccountRow(title: tr("已登录 Grok", "Signed in"), subtitle: "xAI")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .help("已用 xAI 账号登录")
                } else {
                    Button {
                        model.beginLogin()
                    } label: {
                        AccountRow(title: tr("登录", "Sign in"), subtitle: "accounts.x.ai")
                    }
                    .help("打开 accounts.x.ai 的官方登录")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(Theme.sidebar)
        .navigationTitle("Grok")
    }

    private func placeButton(_ place: AppPlace, _ symbol: String) -> some View {
        Button {
            model.place = place
        } label: {
            SidebarRow(title: place.title, symbol: symbol, selected: model.place == place)
        }
        .buttonStyle(.plain)
    }

    private var groups: [DayGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = model.sessions
            .filter { q.isEmpty || $0.title.lowercased().contains(q) }
            .sorted { $0.updatedAt > $1.updatedAt }
        let order = ["今天", "昨天", "更早"]
        return order.compactMap { title in
            let items = filtered.filter { dayLabel($0.updatedAt) == title }
            return items.isEmpty ? nil : DayGroup(title: title, sessions: items)
        }
    }
}

private struct DayGroup: Identifiable {
    var id: String { title }
    var title: String
    var sessions: [ChatSession]
}

private func dayLabel(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) { return "今天" }
    if Calendar.current.isDateInYesterday(date) { return "昨天" }
    return "更早"
}

/// 36pt sidebar row with 12pt radius, 14pt text, hover and selected fills (grok.com).
private struct SidebarRow: View {
    var title: String
    var symbol: String? = nil
    var selected = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(Theme.ui(14))
                    .frame(width: 18)
                    .foregroundStyle(Theme.fg2)
            }
            Text(title)
                .font(Theme.ui(14))
                .foregroundStyle(Theme.fg1)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, symbol == nil ? 9 : 6)
        .padding(.trailing, 8)
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? Theme.surface2 : (hover ? Theme.hover : Color.clear),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hover = $0 }
    }
}

private struct AccountRow: View {
    var title: String
    var subtitle: String
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle.fill")
                .font(Theme.ui(26))
                .foregroundStyle(Theme.fg3)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(Theme.ui(14, .medium)).foregroundStyle(Theme.fg1)
                Text(subtitle).font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hover ? Theme.hover : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hover = $0 }
    }
}
