import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.newSession() } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help(tr("新对话", "New chat"))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            List {
                Section {
                    placeButton(.chat, "square.and.pencil")
                    placeButton(.imagine, "photo")
                    placeButton(.library, "rectangle.stack")
                    placeButton(.automations, "bolt.badge.clock")
                }
                Section {
                    HStack {
                        Button {
                            model.botsOpen.toggle()
                        } label: {
                            Label("Bots", systemImage: model.botsOpen ? "chevron.down" : "chevron.right")
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
                                Text(bot.name).lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.sessions) { session in
                            Button {
                                model.select(session.id)
                            } label: {
                                Text(session.title)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 6)
                                    .background(
                                        session.id == model.activeID ? Color.white.opacity(0.08) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6)
                                    )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(tr("删除", "Delete"), role: .destructive) { model.remove(session.id) }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: tr("搜索", "Search"))
            Divider()
            Group {
                if model.signedIn {
                    Menu {
                        Button(tr("重新登录", "Sign in again")) { model.beginLogin() }
                        Button(tr("退出登录", "Sign out"), role: .destructive) { model.signOut() }
                    } label: {
                        Label(tr("已登录 Grok", "Signed in"), systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .help("已用 xAI 账号登录")
                } else {
                    Button {
                        model.beginLogin()
                    } label: {
                        Label(tr("登录", "Sign in"), systemImage: "person.crop.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .help("打开 accounts.x.ai 的官方登录")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            Button {
                model.place = .hub
                model.hubTab = "connectors"
            } label: {
                Label("Connectors", systemImage: "link")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label(tr("设置", "Settings"), systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .navigationTitle("Grok")
    }

    private func placeButton(_ place: AppPlace, _ symbol: String) -> some View {
        Button {
            model.place = place
        } label: {
            Label(place.title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(model.place == place ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
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
