import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    Button {
                        model.newSession()
                    } label: {
                        Label("新对话", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
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
                                Button("删除", role: .destructive) { model.remove(session.id) }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "搜索")
            Divider()
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label("设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            Button {
                model.cliOpen.toggle()
            } label: {
                Label(model.cliOpen ? "隐藏终端" : "显示终端", systemImage: "terminal")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .navigationTitle("Grok")
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
