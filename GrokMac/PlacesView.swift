import SwiftUI

struct PlacesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.place {
        case .library: LibraryPage().warmPage()
        case .automations: AutomationsPage().warmPage()
        case .hub: HubPage().warmPage()
        default: ChatPane()
        }
    }
}

/// Non-chat pages sit on the same warm-gray page color as the chat instead of the window default.
private extension View {
    func warmPage() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.base)
            .scrollContentBackground(.hidden)
    }
}

private struct LibraryPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.sessions.flatMap { session in
            session.messages.compactMap { message -> (UUID, String, String)? in
                guard let range = message.content.range(of: #"!\[[^\]]*\]\(([^)]+)\)"#, options: .regularExpression) else { return nil }
                let blob = String(message.content[range])
                guard let open = blob.lastIndex(of: "("), let close = blob.lastIndex(of: ")"), open < close else { return nil }
                let url = String(blob[blob.index(after: open)..<close])
                return (message.id, url, session.title)
            }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Library").font(Theme.ui(26))
                Text("生成的图片会收在这里。").foregroundStyle(.secondary)
                if items.isEmpty {
                    Text("还没有图片。去 Imagine 生成一张。").foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 12) {
                        ForEach(items, id: \.0) { item in
                            VStack(alignment: .leading) {
                                AsyncImage(url: URL(string: item.1)) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Color.gray.opacity(0.15)
                                }
                                .frame(height: 160)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                Text(item.2).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AutomationsPage: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var prompt = ""
    @State private var hours = 24

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Automations").font(Theme.ui(26))
                Text("应用开着的时候，到点会在本地开一轮对话。对话里的命令和文件工具仍然只改你选的文件夹。").foregroundStyle(.secondary)
                TextField("名称", text: $name).textFieldStyle(.roundedBorder)
                TextField("到点要做的事", text: $prompt, axis: .vertical).textFieldStyle(.roundedBorder)
                Stepper("每 \(hours) 小时", value: $hours, in: 1...168)
                Button("添加") {
                    guard !prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    model.addAutomation(name: name, prompt: prompt, everyHours: hours)
                    name = ""
                    prompt = ""
                }
                ForEach(model.automations) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text(item.enabled ? "每 \(item.everyHours) 小时" : "已暂停").font(Theme.ui(11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(item.enabled ? "暂停" : "启用") {
                            if let index = model.automations.firstIndex(where: { $0.id == item.id }) {
                                model.automations[index].enabled.toggle()
                            }
                        }
                        Button("删除", role: .destructive) { model.automations.removeAll { $0.id == item.id } }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }
}

private struct HubPage: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SegmentedTabs(selection: Bindable(model).hubTab, options: [
                ("connectors", tr("连接器", "Connectors")),
                ("skills", "Skills"),
                ("bots", tr("机器人", "Bots")),
            ])
            TextField("Search...", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                if model.hubTab == "skills" {
                    SkillsEditor(query: query)
                } else if model.hubTab == "bots" {
                    BotsEditor(query: query)
                } else {
                    ConnectorsList(query: query)
                }
            }
        }
        .padding(24)
    }
}

private struct ConnectorsList: View {
    @Environment(AppModel.self) private var model
    var query: String

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        VStack(alignment: .leading, spacing: 8) {
            Text("Connected").font(Theme.ui(15))
            ForEach(GrokCatalog.connectors.filter { $0.group == "connected" && matches($0, q) }) { item in
                row(item)
            }
            Text("Featured").font(Theme.ui(15)).padding(.top, 12)
            ForEach(GrokCatalog.connectors.filter { $0.group == "featured" && matches($0, q) }) { item in
                row(item)
            }
            Text("Advertising").font(Theme.ui(15)).padding(.top, 12)
            ForEach(GrokCatalog.connectors.filter { $0.group == "advertising" && matches($0, q) }) { item in
                row(item)
            }
            Text("GitHub 让 Grok 在对话里用本机的 gh 命令。其他账号还没有接入，标为即将支持；需要的话可以在 设置 → MCP 服务器 里添加对应的 MCP 服务器。")
                .font(Theme.ui(11))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }

    private func matches(_ item: GrokConnector, _ q: String) -> Bool {
        q.isEmpty || item.name.lowercased().contains(q) || item.blurb.lowercased().contains(q)
    }

    private func row(_ item: GrokConnector) -> some View {
        HStack(spacing: 12) {
            Image("conn-\(item.id)")
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                Text(item.blurb).font(Theme.ui(11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if item.id == "github" {
                Button(model.connected.contains(item.id) ? "✓ Added" : "Add") {
                    model.toggleConnector(item.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text(tr("即将支持", "Coming soon"))
                    .font(Theme.ui(11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SkillsEditor: View {
    @Environment(AppModel.self) private var model
    var query: String
    @State private var name = ""
    @State private var text = ""

    var body: some View {
        let q = query.lowercased()
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.skills.filter { q.isEmpty || $0.name.lowercased().contains(q) }) { skill in
                HStack {
                    VStack(alignment: .leading) {
                        Text(skill.name)
                        Text(skill.text).font(Theme.ui(11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(skill.on ? "已启用" : "启用") {
                        if let index = model.skills.firstIndex(where: { $0.id == skill.id }) {
                            model.skills[index].on.toggle()
                        }
                    }
                    Button("删除", role: .destructive) { model.skills.removeAll { $0.id == skill.id } }
                }
            }
            TextField("技能名称", text: $name).textFieldStyle(.roundedBorder)
            TextField("交给 Grok 的说明", text: $text).textFieldStyle(.roundedBorder)
            Button("New Skill") {
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                model.skills.append(GrokSkill(id: UUID(), name: name.isEmpty ? "Skill" : name, text: text, on: true))
                name = ""
                text = ""
            }
        }
    }
}

private struct BotsEditor: View {
    @Environment(AppModel.self) private var model
    var query: String
    @State private var name = ""
    @State private var prompt = ""

    var body: some View {
        let q = query.lowercased()
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.bots.filter { q.isEmpty || $0.name.lowercased().contains(q) }) { bot in
                HStack {
                    VStack(alignment: .leading) {
                        Text(bot.name + (model.activeBotID == bot.id ? " · 使用中" : ""))
                        Text(bot.prompt).lineLimit(2).font(Theme.ui(11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.activeBotID == bot.id {
                        Button("停用") { model.activeBotID = nil }
                    } else {
                        Button("使用") { model.activeBotID = bot.id; model.place = .chat }
                    }
                    Button("删除", role: .destructive) {
                        if model.activeBotID == bot.id { model.activeBotID = nil }
                        model.bots.removeAll { $0.id == bot.id }
                    }
                }
            }
            TextField("Bot 名称", text: $name).textFieldStyle(.roundedBorder)
            TextField("这个 Bot 怎么做事", text: $prompt, axis: .vertical).textFieldStyle(.roundedBorder)
            Button("New Bot") {
                guard !prompt.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                model.addBot(name: name, prompt: prompt)
                name = ""
                prompt = ""
            }
        }
    }
}
