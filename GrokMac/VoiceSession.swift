import AVFoundation
import Foundation
import Observation

/// Two-way voice over the xAI Realtime (Speech to Speech) WebSocket.
/// Docs: https://docs.x.ai/developers/model-capabilities/audio/speech-to-speech
/// Events: https://docs.x.ai/developers/rest-api-reference/inference/voice
@MainActor
@Observable
final class VoiceSession {
    enum Phase: Equatable {
        case idle, connecting, listening, userSpeaking, grokSpeaking
        case failed(String)
    }

    struct Line: Identifiable, Equatable {
        var id = UUID()
        var fromUser: Bool
        var text: String
    }

    var phase: Phase = .idle
    var lines: [Line] = []

    static let rate: Double = 24_000
    private var socket: URLSessionWebSocketTask?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var converter: AVAudioConverter?
    private var assistantLineID: UUID?
    private var receiveTask: Task<Void, Never>?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VoiceSession.rate, channels: 1, interleaved: false)!
    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: VoiceSession.rate, channels: 1, interleaved: true)!

    var active: Bool {
        switch phase {
        case .idle, .failed: false
        default: true
        }
    }

    func start(key: String, instructions: String, voice: String = "eve") async {
        guard !active else { return }
        let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            phase = .failed("先登录，再开始语音对话。")
            return
        }
        lines = []
        phase = .connecting
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            phase = .failed("没有麦克风权限。在“系统设置 › 隐私与安全性 › 麦克风”里允许 Grok。")
            return
        }

        var request = URLRequest(url: URL(string: "wss://api.x.ai/v1/realtime?model=grok-voice-latest")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()

        send([
            "type": "session.update",
            "session": [
                "voice": voice,
                "instructions": instructions,
                "turn_detection": ["type": "server_vad"],
                "audio": [
                    "input": ["format": ["type": "audio/pcm", "rate": Int(Self.rate)]],
                    "output": ["format": ["type": "audio/pcm", "rate": Int(Self.rate)]],
                ],
            ],
        ])

        receiveTask = Task { [weak self] in await self?.receiveLoop() }

        do {
            try startAudio()
            phase = .listening
        } catch {
            stop()
            phase = .failed("无法打开麦克风：\(error.localizedDescription)")
        }
    }

    func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        engine?.inputNode.removeTap(onBus: 0)
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        converter = nil
        assistantLineID = nil
        if case .failed = phase { return }
        phase = .idle
    }

    // MARK: Audio

    private func startAudio() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Echo cancellation so Grok does not hear itself through the speakers.
        try? input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: wireFormat) else {
            throw NSError(domain: "GrokVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可用的麦克风"])
        }
        self.converter = converter

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)

        let wire = wireFormat
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            let ratio = wire.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
            let data = Data(bytes: samples[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
            let encoded = data.base64EncodedString()
            Task { @MainActor [weak self] in
                self?.send(["type": "input_audio_buffer.append", "audio": encoded])
            }
        }

        try engine.start()
        player.play()
        self.engine = engine
        self.player = player
    }

    private func play(base64: String) {
        guard let player, let data = Data(base64Encoded: base64), data.count >= 2 else { return }
        let frames = data.count / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<frames {
                channel[index] = Float(Int16(littleEndian: samples[index])) / 32768
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    // MARK: Socket

    private func send(_ event: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                let text: String
                switch message {
                case .string(let value): text = value
                case .data(let value): text = String(data: value, encoding: .utf8) ?? ""
                @unknown default: continue
                }
                guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                handle(json)
            } catch {
                if Task.isCancelled || self.socket == nil { return }
                let detail = (socket.closeReason.flatMap { String(data: $0, encoding: .utf8) }) ?? error.localizedDescription
                stop()
                phase = .failed("语音连接断开：\(detail.prefix(160))")
                return
            }
        }
    }

    private func handle(_ json: [String: Any]) {
        switch json["type"] as? String ?? "" {
        case "response.output_audio.delta", "response.audio.delta":
            if let delta = json["delta"] as? String { play(base64: delta) }
            phase = .grokSpeaking
        case "response.output_audio_transcript.delta":
            guard let delta = json["delta"] as? String else { return }
            if let id = assistantLineID, let index = lines.firstIndex(where: { $0.id == id }) {
                lines[index].text += delta
            } else {
                let line = Line(fromUser: false, text: delta)
                assistantLineID = line.id
                lines.append(line)
            }
        case "response.done":
            assistantLineID = nil
            if phase == .grokSpeaking { phase = .listening }
        case "input_audio_buffer.speech_started":
            // Barge-in: the user talks over Grok, so drop what is still queued.
            player?.stop()
            player?.play()
            assistantLineID = nil
            phase = .userSpeaking
        case "input_audio_buffer.speech_stopped":
            phase = .listening
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String, !transcript.isEmpty {
                // Keep the user's words above Grok's reply to them.
                let line = Line(fromUser: true, text: transcript)
                if let id = assistantLineID, let index = lines.firstIndex(where: { $0.id == id }) {
                    lines.insert(line, at: index)
                } else {
                    lines.append(line)
                }
            }
        case "error":
            let detail = ((json["error"] as? [String: Any])?["message"] as? String) ?? "未知错误"
            lines.append(Line(fromUser: false, text: "⚠️ \(detail)"))
        default:
            break
        }
    }
}
