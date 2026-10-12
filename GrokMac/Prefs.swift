import AppKit
import Foundation
import Observation
import SwiftUI
import UserNotifications

/// Local-only app preferences, stored in UserDefaults on this Mac.
@MainActor
@Observable
final class Prefs {
    static let shared = Prefs()
    private let store = UserDefaults.standard

    var theme: String { didSet { store.set(theme, forKey: "grok.pref.theme") } }
    var codeWrap: Bool { didSet { store.set(codeWrap, forKey: "grok.pref.codeWrap") } }
    var autoScroll: Bool { didSet { store.set(autoScroll, forKey: "grok.pref.autoScroll") } }
    /// When on, Return adds a new line and only ⌘↩ sends.
    var commandEnterSends: Bool { didSet { store.set(commandEnterSends, forKey: "grok.pref.cmdEnter") } }
    var notifyOnFinish: Bool { didSet { store.set(notifyOnFinish, forKey: "grok.pref.notify") } }
    var language: String { didSet { store.set(language, forKey: "grok.pref.language") } }
    var customInstructions: String { didSet { store.set(customInstructions, forKey: "grok.pref.instructions") } }
    var stylePreset: String { didSet { store.set(stylePreset, forKey: "grok.pref.preset") } }
    var memories: [String] { didSet { store.set(memories, forKey: "grok.pref.memories") } }
    var useLocation: Bool { didSet { store.set(useLocation, forKey: "grok.pref.location") } }
    var city: String { didSet { store.set(city, forKey: "grok.pref.city") } }
    var refineDictation: Bool { didSet { store.set(refineDictation, forKey: "grok.pref.refineDictation") } }
    var voice: String { didSet { store.set(voice, forKey: "grok.pref.voice") } }

    private init() {
        theme = store.string(forKey: "grok.pref.theme") ?? "dark"
        codeWrap = store.bool(forKey: "grok.pref.codeWrap")
        autoScroll = store.object(forKey: "grok.pref.autoScroll") as? Bool ?? true
        commandEnterSends = store.bool(forKey: "grok.pref.cmdEnter")
        notifyOnFinish = store.bool(forKey: "grok.pref.notify")
        language = store.string(forKey: "grok.pref.language") ?? "zh"
        customInstructions = store.string(forKey: "grok.pref.instructions") ?? ""
        stylePreset = store.string(forKey: "grok.pref.preset") ?? "none"
        memories = store.stringArray(forKey: "grok.pref.memories") ?? []
        useLocation = store.bool(forKey: "grok.pref.location")
        city = store.string(forKey: "grok.pref.city") ?? ""
        refineDictation = store.object(forKey: "grok.pref.refineDictation") as? Bool ?? true
        voice = store.string(forKey: "grok.pref.voice") ?? "eve"
    }

    var colorScheme: ColorScheme? {
        switch theme {
        case "light": .light
        case "system": nil
        default: .dark
        }
    }

    static let presets: [(id: String, zh: String, en: String, prompt: String)] = [
        ("none", "无", "None", ""),
        ("concise", "简洁", "Concise", "Be concise: short, direct answers without preamble."),
        ("formal", "正式", "Formal", "Use a formal, professional tone."),
        ("comprehensive", "详尽", "Comprehensive", "Be comprehensive: cover the topic thoroughly with structure and relevant detail."),
        ("socratic", "苏格拉底式", "Socratic", "Use the Socratic method: guide the user with probing questions instead of handing over the answer."),
        ("tutor", "导师", "Tutor", "Act as a patient tutor: explain step by step, check understanding, and give small exercises."),
    ]

    /// Extra system text sent with every chat and voice request.
    func personalNote() -> String {
        var lines: [String] = []
        if let preset = Self.presets.first(where: { $0.id == stylePreset }), !preset.prompt.isEmpty {
            lines.append("Response style: \(preset.prompt)")
        }
        let custom = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { lines.append("User's custom instructions:\n\(custom)") }
        let saved = memories.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !saved.isEmpty { lines.append("Things the user asked you to remember:\n- " + saved.joined(separator: "\n- ")) }
        if useLocation {
            var place: [String] = []
            let trimmedCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedCity.isEmpty { place.append(trimmedCity) }
            if let region = Locale.current.region?.identifier { place.append("region \(region)") }
            place.append("time zone \(TimeZone.current.identifier)")
            lines.append("Approximate user location for personalization: \(place.joined(separator: ", ")).")
        }
        if language == "en" { lines.append("The app interface is in English.") }
        return lines.joined(separator: "\n")
    }

    /// Removes filler words from spoken text before it is saved to the chat.
    func refine(_ spoken: String) -> String {
        guard refineDictation else { return spoken }
        var text = spoken
        let patterns = [#"(?i)\b(um+|uh+|erm+|you know)\b[,，]?\s*"#, #"[嗯呃啊额]{1,3}[，,。…]*"#, #"(就是说|那个那个|然后然后)"#]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? spoken : trimmed
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted {
                Task { @MainActor in Prefs.shared.notifyOnFinish = false }
            }
        }
    }

    func notifyFinished(title: String, body: String) {
        guard notifyOnFinish, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(160))
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Picks the Chinese or English string for the interface language.
@MainActor
func tr(_ zh: String, _ en: String) -> String {
    Prefs.shared.language == "en" ? en : zh
}
