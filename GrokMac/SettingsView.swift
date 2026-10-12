import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("账号") {
                if model.signedIn {
                    LabeledContent("状态", value: "已登录")
                    Button("退出登录", role: .destructive) { model.signOut() }
                } else {
                    Button("登录") { model.beginLogin() }
                }
                Text("打开 xAI 官方登录页 accounts.x.ai，用 X、Google 或 Apple 授权。")
                    .font(.caption)
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
                    Text("越界才问").tag("on-request")
                    Text("不问").tag("never")
                }
                Toggle("用 Git worktree 隔离改动", isOn: Binding(
                    get: { model.useWorktree },
                    set: { model.setWorktree($0) }
                ))
                Text("应用不再使用 App Sandbox。命令可以读写你的用户目录；删除、覆盖、改工程外文件或联网前会停下来问。完全访问去掉命令级的限制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("撤销上一次改动") { model.undoLastChange() }
            }
            Section("工程文件夹") {
                Text(model.projectLabel)
                    .font(.caption)
                    .textSelection(.enabled)
                Text("对话里 Grok 运行命令时以这个文件夹为当前目录，没选时用你的用户目录。它可以读写用户目录里的任何文件；删除、覆盖或改工程外文件前会先问你。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("选择文件夹") { model.chooseProject() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
        .padding()
    }
}

@MainActor
final class Speaker {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()

    func speakLast(in session: ChatSession) {
        guard let last = session.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty && !$0.pending }) else { return }
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: String(last.content.prefix(500)))
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        synth.speak(utterance)
    }
}
