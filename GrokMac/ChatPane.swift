import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatPane: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var importing = false
    @State private var attachments: [ComposerAttachment] = []
    @State private var dropping = false

    private var visible: [ChatMessage] {
        model.active.messages.filter { $0.role != .meta }
    }

    var body: some View {
        Group {
            if visible.isEmpty {
                VStack(spacing: 20) {
                    Text(model.place == .imagine ? "Imagine" : "Grok")
                        .font(.system(size: 40, weight: .medium))
                    Text(model.place == .imagine ? (model.imagineVideo ? "描述你要的视频" : "描述你要的图片") : "可以直接让 Grok 在这台 Mac 上运行命令、读写工程文件")
                        .foregroundStyle(.secondary)
                    composer
                        .frame(maxWidth: 720)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(visible) { message in
                                MessageRow(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: visible.last?.content) { _, _ in
                        if Prefs.shared.autoScroll, let id = visible.last?.id {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(id, anchor: .bottom)
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    composer
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.base)
        .navigationTitle(model.active.title)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Speaker.shared.speakLast(in: model.active)
                } label: {
                    Image(systemName: "waveform")
                }
                .help(tr("朗读上一条回答", "Read the last reply aloud"))
            }
        }
        .sheet(isPresented: Binding(get: { model.voiceOpen }, set: { if !$0 { model.endVoice() } })) {
            VoicePanel()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .utf8PlainText, .sourceCode, .json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            let clip = String(text.prefix(20_000))
            draft = draft.isEmpty ? clip : draft + "\n\n" + clip
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { item in
                            AttachmentChip(item: item) { attachments.removeAll { $0.id == item.id } }
                        }
                    }
                }
                if attachments.contains(where: { $0.kind == .pdf }) {
                    Text("PDF 只发送提取出的文字（最多 \(ComposerAttachment.maxPDFChars / 1000)k 字符），扫描件里的图片不会被读取。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            TextField(Prefs.shared.commandEnterSends ? tr("询问任何问题（⌘↩ 发送）", "Ask anything (⌘↩ to send)") : tr("询问任何问题", "Ask anything"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .onKeyPress(keys: [.return]) { press in
                    guard Prefs.shared.commandEnterSends else { return .ignored }
                    if press.modifiers.contains(.command) {
                        submit()
                    } else if !press.modifiers.contains(.shift) {
                        draft += "\n"
                    } else {
                        return .ignored
                    }
                    return .handled
                }
                .onSubmit { if !Prefs.shared.commandEnterSends { submit() } }
            HStack {
                Menu {
                    Button(tr("插入文本文件", "Insert text file")) { importing = true }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)

                if model.place != .imagine {
                    Button {
                        pickAttachments()
                    } label: {
                        Image(systemName: "paperclip")
                    }
                    .buttonStyle(.plain)
                    .help(tr("添加图片或 PDF（也可以直接拖进来）", "Add images or PDFs (or drag them in)"))
                }

                Menu {
                    ForEach(ReplyTier.allCases) { tier in
                        Button {
                            model.tier = tier
                        } label: {
                            if model.tier == tier {
                                Label("\(tier.title) · \(tier.hint)", systemImage: "checkmark")
                            } else {
                                Text("\(tier.title) · \(tier.hint)")
                            }
                        }
                    }
                } label: {
                    Text(model.tier.title)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if model.place == .imagine {
                    Picker("", selection: Binding(get: { model.imagineVideo }, set: { model.imagineVideo = $0 })) {
                        Text("图片").tag(false)
                        Text("视频").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("生成图片或视频")
                }

                if model.place != .imagine {
                    SearchToggle(title: tr("联网", "Web"), icon: "globe", on: model.webSearch) { model.webSearch.toggle() }
                        .help("让 Grok 搜索网页并附上来源")
                    SearchToggle(title: "X", icon: "at", on: model.xSearch) { model.xSearch.toggle() }
                        .help("让 Grok 搜索 X 上的帖子")
                }

                Spacer()
                if model.place != .imagine {
                    Button {
                        model.startVoice()
                    } label: {
                        Image(systemName: "mic")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(tr("语音对话", "Voice mode"))
                    .disabled(model.busy)
                }
                Button {
                    if model.busy { model.stop() } else { submit() }
                } label: {
                    Image(systemName: model.busy ? "stop.fill" : "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(canSend || model.busy ? Theme.buttonFilled : Theme.buttonDisabled))
                        .foregroundStyle(canSend || model.busy ? Theme.buttonFilledFg : Theme.fg3)
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !model.busy)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(12)
        .background(Theme.composer, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(dropping ? Color.accentColor : Theme.composerBorder))
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard model.place != .imagine else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in addAttachment(url) }
                }
            }
            return true
        }
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf]
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(addAttachment)
    }

    private func addAttachment(_ url: URL) {
        guard attachments.count < 8 else { return }
        if let item = ComposerAttachment.load(url) {
            attachments.append(item)
        }
    }

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) && !model.busy
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, !model.busy else { return }
        let files = attachments
        draft = ""
        attachments = []
        model.send(text, surface: .web, attachments: files)
    }
}

private struct MessageRow: View {
    var message: ChatMessage

    var body: some View {
        if message.role == .tool, let tool = message.tool {
            ToolCardView(tool: tool)
        } else if message.role == .user {
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .leading, spacing: 4) {
                    if message.surface == .cli {
                        Text("来自终端")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let files = message.files, !files.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(message.allImages.prefix(4), id: \.self) { url in
                                if let image = dataImage(url) {
                                    Image(nsImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        ForEach(files.filter { $0.lowercased().hasSuffix(".pdf") }, id: \.self) { name in
                            Label(name, systemImage: "doc.richtext")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(message.content)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 16))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if let thought = message.reasoning, !thought.isEmpty {
                    ThinkingSection(text: thought, live: message.pending && message.content.isEmpty)
                }
                if message.pending, message.content.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    MarkdownView(text: message.content)
                        .foregroundStyle(message.error ? Theme.danger : Color.primary)
                }
                if let path = message.video {
                    VideoCard(url: URL(fileURLWithPath: path))
                }
                if let links = message.citations, !links.isEmpty {
                    SourceList(links: links)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SearchToggle: View {
    var title: String
    var icon: String
    var on: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.25) : Theme.surface2))
                .foregroundStyle(on ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct SourceList: View {
    var links: [String]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("来源 · \(links.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(links.prefix(expanded ? links.count : 5).enumerated()), id: \.offset) { index, link in
                if let url = URL(string: link) {
                    Link(destination: url) {
                        Text("\(index + 1). \(url.host() ?? link)\(url.path().count > 1 ? url.path() : "")")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .help(link)
                }
            }
            if links.count > 5 {
                Button(expanded ? "收起" : "显示全部 \(links.count) 个来源") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }
}

private struct ThinkingSection: View {
    var text: String
    var live: Bool
    @State private var expanded: Bool? = nil

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded ?? live }, set: { expanded = $0 })) {
            ScrollView {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .padding(.leading, 4)
        } label: {
            Label(live ? "思考中…" : "思考过程", systemImage: "brain")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 12))
    }
}

private func dataImage(_ url: String) -> NSImage? {
    guard let comma = url.firstIndex(of: ","), let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
    return NSImage(data: data)
}

private struct AttachmentChip: View {
    var item: ComposerAttachment
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if item.kind == .image, let url = item.dataURL, let image = dataImage(url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "doc.richtext")
            }
            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 140)
            if item.kind == .pdf {
                Text("文字 \((item.text ?? "").count) 字")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("移除")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.surface2))
    }
}

private struct VideoCard: View {
    var url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if FileManager.default.fileExists(atPath: url.path) {
                VideoPlayer(player: player)
                    .frame(maxWidth: 560)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onAppear { if player == nil { player = AVPlayer(url: url) } }
                HStack {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("存储为…") { saveCopy() }
                }
                .buttonStyle(.link)
                .font(.caption)
            } else {
                Text("视频文件已不在本机。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func saveCopy() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Grok Imagine.mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: url, to: target)
    }
}

private struct VoicePanel: View {
    @Environment(AppModel.self) private var model

    private var status: String {
        switch model.voice.phase {
        case .idle: "未连接"
        case .connecting: "正在连接…"
        case .listening: "正在听"
        case .userSpeaking: "你在说话"
        case .grokSpeaking: "Grok 正在说"
        case .failed(let message): message
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("语音对话")
                .font(.title2.weight(.medium))
            Image(systemName: model.voice.phase == .grokSpeaking ? "waveform" : "mic.fill")
                .font(.system(size: 44))
                .symbolEffect(.pulse, isActive: model.voice.active)
                .foregroundStyle(model.voice.active ? Color.primary : Color.secondary)
                .frame(height: 64)
            Text(status)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.voice.lines) { line in
                            Text((line.fromUser ? "你：" : "Grok：") + line.text)
                                .foregroundStyle(line.fromUser ? Color.secondary : Color.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(4)
                }
                .onChange(of: model.voice.lines.last?.text) { _, _ in
                    if let id = model.voice.lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .frame(height: 200)
            HStack {
                if case .failed = model.voice.phase {
                    Button("重试") { model.startVoice() }
                }
                Button("结束") { model.endVoice() }
                    .keyboardShortcut(.cancelAction)
            }
            Text("说完会自动发送，随时可以打断。结束后对话文字会保存到当前会话。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 420)
    }
}
