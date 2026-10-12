import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label(tr("通用", "General"), systemImage: "gearshape") }
            PersonalSettings()
                .tabItem { Label(tr("个性化", "Personalize"), systemImage: "person.text.rectangle") }
            VoiceSettings()
                .tabItem { Label(tr("语音", "Voice"), systemImage: "waveform") }
            DataSettings()
                .tabItem { Label(tr("数据", "Data"), systemImage: "externaldrive") }
            accountForm
                .tabItem { Label(tr("账号与工具", "Account & tools"), systemImage: "terminal") }
        }
        .frame(width: 560, height: 560)
        .background(Theme.base.ignoresSafeArea())
        .tint(Theme.link)
        .foregroundStyle(Theme.fg1)
    }

    private var accountForm: some View {
        Form {
            Section("账号") {
                if model.signedIn {
                    LabeledContent("状态", value: "已登录")
                    Button("退出登录", role: .destructive) { model.signOut() }
                } else {
                    Button("登录") { model.beginLogin() }
                }
                Text("打开 xAI 官方登录页 accounts.x.ai，用 X、Google 或 Apple 授权。")
                    .font(Theme.ui(11))
                    .foregroundStyle(.secondary)
            }
            Section("沙箱") {
                Picker("范围", selection: Binding(
                    get: { model.sandboxMode },
                    set: { model.setSandbox($0) }
                )) {
                    Text("只读").tag("read-only")
                    Text("项目内可写").tag("workspace-write")
                    Text("完全访问").tag("full-access")
                }
                Picker("批准", selection: Binding(
                    get: { model.approvalPolicy },
                    set: { model.setApproval($0) }
                )) {
                    ForEach(ApprovalMode.all, id: \.tag) { mode in
                        Text(mode.title).tag(mode.tag)
                    }
                }
                Toggle("用 Git worktree 隔离改动", isOn: Binding(
                    get: { model.useWorktree },
                    set: { model.setWorktree($0) }
                ))
                Text("应用不再使用 App Sandbox。命令可以读写你的用户目录；删除、覆盖、改工程外文件或联网前会停下来问。完全访问去掉命令级的限制。")
                    .font(Theme.ui(11))
                    .foregroundStyle(.secondary)
                Button("撤销上一次改动") { model.undoLastChange() }
            }
            Section("工程文件夹") {
                Text(model.projectLabel)
                    .font(Theme.ui(11))
                    .textSelection(.enabled)
                Text("对话里 Grok 运行命令时以这个文件夹为当前目录，没选时用你的用户目录。它可以读写用户目录里的任何文件；删除、覆盖或改工程外文件前会先问你。")
                    .font(Theme.ui(11))
                    .foregroundStyle(.secondary)
                Button("选择文件夹") { model.chooseProject() }
            }
        }
        .warmForm()
    }
}

private struct GeneralSettings: View {
    @Bindable private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section(tr("外观", "Appearance")) {
                Picker(tr("主题", "Theme"), selection: $prefs.theme) {
                    Text(tr("深色", "Dark")).tag("dark")
                    Text(tr("浅色", "Light")).tag("light")
                    Text(tr("跟随系统", "System")).tag("system")
                }
                Toggle(tr("代码块自动换行", "Wrap long lines in code blocks"), isOn: $prefs.codeWrap)
                Picker(tr("界面语言", "Interface language"), selection: $prefs.language) {
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                Text(tr("界面语言目前覆盖设置、输入框和侧边栏；其余文字仍是中文。", "English currently covers Settings, the composer and the sidebar; other text is still Chinese."))
                    .font(Theme.ui(11))
                    .foregroundStyle(.secondary)
            }
            Section(tr("对话", "Chat")) {
                Toggle(tr("回答时自动滚到底部", "Auto-scroll while Grok replies"), isOn: $prefs.autoScroll)
                Toggle(tr("用 ⌘↩ 发送（↩ 换行）", "Send with ⌘↩ (↩ adds a new line)"), isOn: $prefs.commandEnterSends)
                Toggle(tr("回答完成时发通知", "Notify when a reply finishes"), isOn: Binding(
                    get: { prefs.notifyOnFinish },
                    set: { on in
                        prefs.notifyOnFinish = on
                        if on { prefs.requestNotifications() }
                    }
                ))
                Text(tr("只在应用不在前台时通知。", "Only when the app is in the background."))
                    .font(Theme.ui(11))
                    .foregroundStyle(.secondary)
            }
        }
        .warmForm()
    }
}

private struct PersonalSettings: View {
    @Bindable private var prefs = Prefs.shared
    @State private var newMemory = ""
    @State private var editing: Int?
    @State private var editText = ""

    var body: some View {
        Form {
            Section(tr("回答风格", "Response style")) {
                Picker(tr("预设", "Preset"), selection: $prefs.stylePreset) {
                    ForEach(Prefs.presets, id: \.id) { preset in
                        Text(tr(preset.zh, preset.en)).tag(preset.id)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("自定义指令", "Custom instructions"))
                    TextEditor(text: $prefs.customInstructions)
                        .font(Theme.ui(13))
                        .frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                }
                Text(tr("每次请求都会把预设和自定义指令发给 Grok，只存在这台 Mac 上。", "The preset and instructions go with every request and are stored only on this Mac."))
                    .font(Theme.ui(11))
                    .foregroundStyle(.secondary)
            }
            Section(tr("本地记忆", "Local memory")) {
                if prefs.memories.isEmpty {
                    Text(tr("还没有记忆。", "No memories yet."))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(prefs.memories.enumerated()), id: \.offset) { index, memory in
                    if editing == index {
                        HStack {
                            TextField("", text: $editText)
                                .onSubmit { saveEdit(index) }
                            Button(tr("保存", "Save")) { saveEdit(index) }
                            Button(tr("取消", "Cancel")) { editing = nil }
                        }
                    } else {
                        HStack {
                            Text(memory)
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                editText = memory
                                editing = index
                            } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                                .help(tr("编辑", "Edit"))
                            Button(role: .destructive) {
                                editing = nil
                                prefs.memories.remove(at: index)
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help(tr("删除", "Delete"))
                        }
                    }
                }
                HStack {
                    TextField(tr("添加一条，比如：我用 Swift 写 Mac 应用", "Add one, e.g. I build Mac apps in Swift"), text: $newMemory)
                        .onSubmit(addMemory)
                    Button(tr("添加", "Add"), action: addMemory)
                        .disabled(newMemory.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !prefs.memories.isEmpty {
                    Button(tr("清空全部记忆", "Delete all memories"), role: .destructive) {
                        editing = nil
                        prefs.memories = []
                    }
                }
            }
            Section(tr("位置", "Location")) {
                Toggle(tr("用大致位置个性化回答", "Personalize answers with approximate location"), isOn: $prefs.useLocation)
                if prefs.useLocation {
                    TextField(tr("城市（可选）", "City (optional)"), text: $prefs.city)
                }
                Text(tr("只发送你填的城市、系统地区和时区，不读取 GPS。", "Only the city you enter, your system region and time zone are sent. No GPS."))
                    .font(Theme.ui(11))
                    .foregroundStyle(.secondary)
            }
        }
        .warmForm()
    }

    private func addMemory() {
        let text = newMemory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prefs.memories.append(String(text.prefix(500)))
        newMemory = ""
    }

    private func saveEdit(_ index: Int) {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if prefs.memories.indices.contains(index) {
            if text.isEmpty { prefs.memories.remove(at: index) } else { prefs.memories[index] = String(text.prefix(500)) }
        }
        editing = nil
    }
}

private struct VoiceSettings: View {
    @Bindable private var prefs = Prefs.shared
    @State private var voices: [String] = ["eve", "ara", "altair", "atlas", "aurora", "carina", "castor", "celeste"]

    var body: some View {
        Form {
            Section(tr("实时语音", "Realtime voice")) {
                Picker(tr("声音", "Voice"), selection: $prefs.voice) {
                    ForEach(voices.contains(prefs.voice) ? voices : [prefs.voice] + voices, id: \.self) { id in
                        Text(id.capitalized).tag(id)
                    }
                }
                Toggle(tr("整理口述内容", "Refine dictation"), isOn: $prefs.refineDictation)
                Text(tr("开启后会提示 Grok 忽略口头禅，存进对话的文字也会去掉“嗯、呃、um”等填充词。", "Grok is told to ignore filler words, and saved transcripts drop fillers like “um” and “uh”."))
                    .font(Theme.ui(11))
                    .foregroundStyle(.secondary)
            }
        }
        .warmForm()
        .task { await loadVoices() }
    }

    /// Built-in voices from GET /v1/tts/voices (https://docs.x.ai/developers/model-capabilities/audio/text-to-speech).
    private func loadVoices() async {
        let key = KeychainStore.load().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var request = URLRequest(url: URL(string: "https://api.x.ai/v1/tts/voices")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["voices"] as? [[String: Any]]
        else { return }
        let ids = list.compactMap { $0["voice_id"] as? String }
        if !ids.isEmpty { voices = ids }
    }
}

private struct DataSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false
    @State private var status = ""

    var body: some View {
        Form {
            Section(tr("对话", "Conversations")) {
                LabeledContent(tr("共有", "Total"), value: "\(model.sessions.count)")
                Button(tr("导出全部对话…", "Export all conversations…")) { model.exportConversations() }
                Button(tr("删除全部对话…", "Delete all conversations…"), role: .destructive) { confirmDelete = true }
            }
            Section(tr("缓存", "Cache")) {
                Button(tr("清除缓存", "Clear cache")) {
                    let freed = model.clearCache()
                    status = tr("已清除缓存，释放 \(freed)。", "Cache cleared, freed \(freed).")
                }
                Text(tr("会删掉网络缓存和生成的视频文件，对话不受影响。", "Removes the network cache and generated video files. Conversations stay."))
                    .font(Theme.ui(11))
                    .foregroundStyle(.secondary)
            }
            if !status.isEmpty {
                Text(status)
                    .font(Theme.ui(11))
            }
        }
        .warmForm()
        .confirmationDialog(tr("删除全部对话？", "Delete all conversations?"), isPresented: $confirmDelete) {
            Button(tr("删除", "Delete"), role: .destructive) {
                model.deleteAllConversations()
                status = tr("已删除全部对话。", "All conversations deleted.")
            }
        } message: {
            Text(tr("这台 Mac 上的所有对话都会被删除，无法恢复。建议先导出。", "Every conversation on this Mac is removed and cannot be restored. Export first if you need them."))
        }
    }
}

@MainActor
final class Speaker {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()

    func speakLast(in session: ChatSession) {
        guard let last = session.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty && !$0.pending }) else { return }
        speak(last.content)
    }

    func speak(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: String(text.prefix(500)))
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        synth.speak(utterance)
    }
}

extension View {
    /// Grouped settings form on the app's warm-gray Theme: page in Theme.base, row groups in
    /// Theme.surface1 with a Theme.border1 hairline, Inter text, link-blue controls.
    func warmForm() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Theme.base)
            .environment(\.defaultMinListRowHeight, 36)
    }
}
