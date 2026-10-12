import AVFoundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var key = KeychainStore.load()
    @State private var saved = false

    var body: some View {
        Form {
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
        .frame(width: 460, height: 220)
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
