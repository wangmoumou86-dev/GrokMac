import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("账号") {
                Button("登录") { model.beginLogin() }
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
                Text("默认和 Codex 一样：只在你选的文件夹里写，命令没有网络。要联网或在只读模式里改文件，才会停下来问。完全访问等于拆掉沙箱。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("撤销上一次改动") { model.undoLastChange() }
            }
            Section("工程文件夹") {
                Text(model.projectLabel)
                    .font(.caption)
                    .textSelection(.enabled)
                Text("终端里的 bash、读写和搜索都作用在这个文件夹。别的目录不会被改。")
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
