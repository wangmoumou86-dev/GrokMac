import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var key = KeychainStore.load()
    @State private var saved = false

    var body: some View {
        Form {
            Section("工具") {
                Toggle("改动前先确认", isOn: Binding(
                    get: { !model.autoRun },
                    set: { model.autoRun = !$0 }
                ))
                Toggle("命令可以联网", isOn: Binding(
                    get: { model.allowNetwork },
                    set: { model.allowNetwork = $0 }
                ))
                Text("提问和计划模式不会改文件。代码模式默认每次改动都要你点允许。撤销在终端里输入 /undo。")
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
            Section("xAI API Key") {
                SecureField("xai-…", text: $key)
                Text("只保存在这台 Mac 的钥匙串。到 console.x.ai 创建。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("保存") {
                        KeychainStore.save(key)
                        model.needsKey = KeychainStore.load().isEmpty
                        saved = true
                    }
                    if saved {
                        Text("已保存")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
        .padding()
        .onChange(of: key) { _, _ in saved = false }
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
