import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatPane: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var importing = false
    @State private var attachments: [ComposerAttachment] = []
    @State private var dropping = false
    @State private var modelHover = false

    /// The tool card that is waiting for approval or an answer; the inline GateBar sits under it.
    /// Falls back to the last message when the gate has no card (e.g. a plain question).
    private var gateAnchor: UUID? {
        guard !model.gateTitle.isEmpty else { return nil }
        return visible.last(where: { $0.role == .tool && ($0.tool?.status == "approval" || $0.tool?.status == "ask") })?.id ?? visible.last?.id
    }

    private var visible: [ChatMessage] {
        model.active.messages.filter { $0.role != .meta }
    }

    var body: some View {
        Group {
            if visible.isEmpty {
                // grok.com places the greeting and composer about a quarter down the page, not centered.
                VStack(spacing: 32) {
                    Spacer(minLength: 0)
                    Text(model.place == .imagine ? tr("想象点什么？", "What should we imagine?") : tr("今天有什么可以帮你？", "How can I help you today?"))
                        .font(Theme.ui(24, .semibold))
                        .tracking(-0.48)
                        .foregroundStyle(Theme.fg1)
                    composer
                        .frame(maxWidth: Theme.composerWidth)
                    Spacer(minLength: 0)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 38) {
                            ForEach(visible) { message in
                                MessageRow(message: message)
                                    .id(message.id)
                                if message.id == gateAnchor {
                                    GateBar(inline: true)
                                        .id("gate")
                                        .padding(.top, -12)
                                }
                            }
                        }
                        .padding(.vertical, 24)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: Theme.contentWidth + 48)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: model.gateTitle) { _, title in
                        guard !title.isEmpty else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("gate", anchor: .bottom) }
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
                        .padding(.bottom, 24)
                        .frame(maxWidth: Theme.composerWidth + 48)
                        .frame(maxWidth: .infinity)
                        .background(alignment: .bottom) {
                            // Opaque strip under the composer with a short fade, so scrolled replies don't show through.
                            VStack(spacing: 0) {
                                LinearGradient(colors: [Theme.base.opacity(0), Theme.base], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 24)
                                Theme.base
                            }
                            .padding(.top, -24)
                            .allowsHitTesting(false)
                        }
                }
            }
        }
        .background(Theme.base)
        .navigationTitle(model.active.title)
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
                        .font(Theme.ui(10))
                        .foregroundStyle(.secondary)
                }
            }
            TextField(Prefs.shared.commandEnterSends ? tr("询问任何问题（⌘↩ 发送）", "Ask anything (⌘↩ to send)") : tr("询问任何问题", "Ask anything"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.ui(16))
                .lineSpacing(Theme.scaled(6))
                .lineLimit(1...6)
                .padding(.horizontal, 8)
                .padding(.top, 14)
                .padding(.bottom, 6)
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
            HStack(spacing: 4) {
                Menu {
                    Button(tr("插入文本文件", "Insert text file")) { importing = true }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 40, height: 40)
                .contentShape(Circle())

                if model.place != .imagine {
                    Button {
                        pickAttachments()
                    } label: {
                        Image(systemName: "paperclip")
                    }
                    .buttonStyle(ComposerIconButtonStyle())
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
                        .font(Theme.ui(14, .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(Capsule().fill(modelHover ? Theme.hover : Color.clear))
                .onHover { modelHover = $0 }
                .help(tr("选择模型", "Choose model"))

                if model.place != .imagine {
                    ApprovalPill()
                }

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


                Spacer()
                Button {
                    if model.busy { model.stop() } else { submit() }
                } label: {
                    Image(systemName: model.busy ? "stop.fill" : "arrow.up")
                        .font(Theme.ui(15, .semibold))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(canSend || model.busy ? Theme.buttonFilled : Theme.buttonDisabled))
                        .foregroundStyle(canSend || model.busy ? Theme.buttonFilledFg : Theme.fg3)
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !model.busy)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, attachments.isEmpty ? 0 : 10)
        .frame(minHeight: 102)
        .background(Theme.composer, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(dropping ? Color.accentColor : Theme.composerBorder, lineWidth: 1))
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
        AttachedPanel.present(panel) { response in
            guard response == .OK else { return }
            panel.urls.forEach(addAttachment)
        }
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
                Spacer(minLength: Theme.contentWidth * 0.3)
                VStack(alignment: .leading, spacing: 4) {
                    if message.surface == .cli {
                        Text("来自终端")
                            .font(Theme.ui(11))
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
                                .font(Theme.ui(11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(message.content)
                        .font(Theme.ui(15))
                        .lineSpacing(Theme.scaled(7.5))
                        .foregroundStyle(Theme.fg1)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let thought = message.reasoning, !thought.isEmpty {
                    ThinkingSection(text: thought, live: message.pending && message.content.isEmpty)
                }
                if message.pending, message.content.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    MarkdownView(text: message.content)
                        .foregroundStyle(message.error ? Theme.danger : Theme.fg1)
                }
                if let path = message.video {
                    VideoCard(url: URL(fileURLWithPath: path))
                }
                if let links = message.citations, !links.isEmpty {
                    SourceList(links: links)
                }
                if !message.pending, !message.content.isEmpty {
                    ReplyActions(text: message.content)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SourceList: View {
    var links: [String]
    @State private var expanded = false

    private var urls: [URL] { links.compactMap { URL(string: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 4) {
                    HStack(spacing: -6) {
                        ForEach(Array(urls.prefix(3).enumerated()), id: \.offset) { _, url in
                            Favicon(host: url.host() ?? "")
                        }
                    }
                    Text(tr("\(links.count) 个来源", "\(links.count) sources"))
                        .font(Theme.ui(14))
                        .foregroundStyle(Theme.fg1)
                        .padding(.leading, 2)
                }
                .padding(.leading, 4)
                .padding(.trailing, 8)
                .frame(height: 31)
                .background(Capsule().fill(Theme.surface1))
                .overlay(Capsule().stroke(Theme.border1, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(tr("显示来源", "Show sources"))
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                        Link(destination: url) {
                            HStack(spacing: 6) {
                                Favicon(host: url.host() ?? "")
                                Text("\(url.host() ?? url.absoluteString)\(url.path().count > 1 ? url.path() : "")")
                                    .font(Theme.ui(13))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .foregroundStyle(Theme.fg2)
                        .help(url.absoluteString)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.top, 4)
    }
}

private struct Favicon: View {
    var host: String

    var body: some View {
        AsyncImage(url: URL(string: "https://www.google.com/s2/favicons?sz=32&domain=\(host)")) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Text(String(host.replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased())
                .font(Theme.ui(9, .semibold))
                .foregroundStyle(Theme.fg2)
        }
        .frame(width: 14, height: 14)
        .clipShape(Circle())
        .frame(width: 20, height: 20)
        .background(Circle().fill(Theme.base))
        .overlay(Circle().stroke(Theme.border1, lineWidth: 1))
    }
}

private struct ThinkingSection: View {
    var text: String
    var live: Bool
    @State private var expanded: Bool? = nil

    private var isOpen: Bool { expanded ?? live }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded = !isOpen }
            } label: {
                HStack(spacing: 4) {
                    Text(live ? tr("思考中…", "Thinking…") : tr("已思考", "Thought"))
                    Image(systemName: "chevron.right")
                        .font(Theme.ui(10, .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .font(Theme.ui(14))
                .foregroundStyle(Theme.fg2)
                .padding(.top, 12)
                .frame(height: 36, alignment: .bottom)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                ScrollView {
                    Text(text)
                        .font(Theme.ui(14))
                        .lineSpacing(Theme.scaled(4))
                        .foregroundStyle(Theme.fg2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.border2).frame(width: 2)
                }
            }
        }
    }
}

private struct ReplyActions: View {
    var text: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(ComposerIconButtonStyle(size: 32))
            .help(tr("复制回答", "Copy reply"))
            Button {
                Speaker.shared.speak(text)
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(ComposerIconButtonStyle(size: 32))
            .help(tr("朗读", "Read aloud"))
        }
        .padding(.leading, -6)
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
                .font(Theme.ui(11))
                .lineLimit(1)
                .frame(maxWidth: 140)
            if item.kind == .pdf {
                Text("文字 \((item.text ?? "").count) 字")
                    .font(Theme.ui(10))
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

/// AppKit AVPlayerView instead of SwiftUI's VideoPlayer: _AVKit_SwiftUI aborts while
/// instantiating VideoPlayer metadata on macOS 26.7 (getSuperclassMetadata), crashing any chat with a video.
private struct PlayerView: NSViewRepresentable {
    var player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

private struct VideoCard: View {
    var url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if FileManager.default.fileExists(atPath: url.path) {
                PlayerView(player: player)
                    .frame(maxWidth: 560)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onAppear { if player == nil { player = AVPlayer(url: url) } }
                HStack {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("存储为…") { saveCopy() }
                }
                .buttonStyle(.link)
                .font(Theme.ui(11))
            } else {
                Text("视频文件已不在本机。")
                    .font(Theme.ui(11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func saveCopy() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Grok Imagine.mp4"
        panel.allowedContentTypes = [.mpeg4Movie]
        let source = url
        AttachedPanel.present(panel) { response in
            guard response == .OK, let target = panel.url else { return }
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: source, to: target)
        }
    }
}

/// 40pt round icon button used inside the composer (attach).
struct ComposerIconButtonStyle: ButtonStyle {
    var size: CGFloat = 40

    func makeBody(configuration: Configuration) -> some View {
        HoverCircle(pressed: configuration.isPressed, size: size) { configuration.label }
    }
}

private struct HoverCircle<Label: View>: View {
    var pressed: Bool
    var size: CGFloat
    @ViewBuilder var label: Label
    @State private var hover = false

    var body: some View {
        label
            .font(Theme.ui(size >= 40 ? 16 : 14))
            .foregroundStyle(Theme.fg2)
            .frame(width: size, height: size)
            .background(Circle().fill(hover || pressed ? Theme.hover : Color.clear))
            .contentShape(Circle())
            .onHover { hover = $0 }
    }
}


/// Compact approval-mode menu in the composer; reads and writes the same policy as Settings.
private struct ApprovalPill: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false

    var body: some View {
        let current = ApprovalMode.current(model.approvalPolicy)
        let risky = current.tag == "never"
        Menu {
            ForEach(ApprovalMode.all, id: \.tag) { mode in
                Button {
                    model.setApproval(mode.tag)
                } label: {
                    Image(systemName: mode.tag == current.tag ? "checkmark" : mode.icon)
                    Text(mode.title)
                    Text(mode.detail)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: current.icon)
                Text(current.title)
            }
            .font(Theme.ui(13, .medium))
            .foregroundStyle(risky ? Color.orange : Theme.fg2)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Capsule().fill(risky ? Color.orange.opacity(0.12) : (hover ? Theme.hover : Color.clear)))
        .onHover { hover = $0 }
        .help("\(current.title)：\(current.detail)")
    }
}
