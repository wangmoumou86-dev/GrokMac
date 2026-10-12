import Foundation
import Observation
import SwiftUI

/// One API response's token usage, exactly as the `usage` object of `response.completed` reported it.
struct UsageRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var model: String
    var session: UUID?
    var input: Int
    var output: Int
    var reasoning: Int
    var cached: Int
    var total: Int
    /// `cost_in_usd_ticks` when the API sent it (1 tick = 1e-10 USD); nil when it did not.
    var costTicks: Int?
}

/// Local usage ledger in ~/Library/Application Support/GrokMac/usage.json. Only numbers the API returned.
@MainActor @Observable
final class UsageStore {
    static let shared = UsageStore()

    private(set) var records: [UsageRecord] = []
    /// Rate-limit style headers from the latest api.x.ai response (empty when the API sent none).
    private(set) var limitHeaders: [String: String] = [:]
    private(set) var limitHeadersAt: Date?
    /// Names of every header on the latest response, so the page can say plainly that no quota was exposed.
    private(set) var lastHeaderNames: [String] = []
    /// Conversation the running agent turn belongs to; set by AppModel before each run.
    var currentSession: UUID?

    private init() { load() }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GrokMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage.json")
    }

    private struct Disk: Codable {
        var records: [UsageRecord]
        var limitHeaders: [String: String]
        var limitHeadersAt: Date?
        var lastHeaderNames: [String]?
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let disk = try? JSONDecoder.iso.decode(Disk.self, from: data) else { return }
        records = disk.records
        limitHeaders = disk.limitHeaders
        limitHeadersAt = disk.limitHeadersAt
        lastHeaderNames = disk.lastHeaderNames ?? []
    }

    private func save() {
        let disk = Disk(records: records, limitHeaders: limitHeaders, limitHeadersAt: limitHeadersAt, lastHeaderNames: lastHeaderNames)
        if let data = try? JSONEncoder.iso.encode(disk) { try? data.write(to: Self.fileURL, options: .atomic) }
    }

    /// Called from GrokClient with the raw `usage` object and the HTTP response headers.
    func record(model: String, usage: [String: Any]?, headers: [AnyHashable: Any]) {
        var names: [String] = []
        var limits: [String: String] = [:]
        for (key, value) in headers {
            let name = String(describing: key).lowercased()
            names.append(name)
            if name.contains("ratelimit") || name.contains("rate-limit") || name.contains("quota") || name.contains("remaining") || name == "retry-after" {
                limits[name] = String(describing: value)
            }
        }
        lastHeaderNames = names.sorted()
        if !limits.isEmpty { limitHeaders = limits; limitHeadersAt = .now }
        if let usage {
            func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
            let inDetail = usage["input_tokens_details"] as? [String: Any] ?? [:]
            let outDetail = usage["output_tokens_details"] as? [String: Any] ?? [:]
            records.append(UsageRecord(
                date: .now, model: model, session: currentSession,
                input: int(usage["input_tokens"]), output: int(usage["output_tokens"]),
                reasoning: int(outDetail["reasoning_tokens"]), cached: int(inDetail["cached_tokens"]),
                total: int(usage["total_tokens"]),
                costTicks: (usage["cost_in_usd_ticks"] as? NSNumber)?.intValue))
        }
        save()
    }

    func clear() { records = []; save() }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

/// Settings → 用量.
struct UsageSettings: View {
    @Environment(AppModel.self) private var model
    @State private var store = UsageStore.shared
    @State private var range = 0

    private var days: Int { [1, 7, 30][range] }
    private var since: Date {
        days == 1 ? Calendar.current.startOfDay(for: .now) : Calendar.current.date(byAdding: .day, value: -days, to: .now)!
    }
    private var rows: [UsageRecord] { store.records.filter { $0.date >= since } }

    var body: some View {
        Form {
            Section {
                Picker("", selection: $range) {
                    Text(tr("今天", "Today")).tag(0)
                    Text(tr("7 天", "7 days")).tag(1)
                    Text(tr("30 天", "30 days")).tag(2)
                }
                .pickerStyle(.segmented).labelsHidden()
                totals(rows)
            } header: {
                Text(tr("本机记录的用量", "Usage recorded on this Mac"))
            } footer: {
                Text(tr("来自每次 API 回复里的 usage 字段，只统计这台 Mac 上这个应用发出的请求。图片和视频生成不计在内。",
                        "From the usage field of every API response; only requests this app sent from this Mac. Image and video generation are not counted."))
                    .font(Theme.ui(11)).foregroundStyle(.secondary)
            }
            Section(tr("按模型", "By model")) {
                let groups = Dictionary(grouping: rows, by: \.model).sorted { $0.key < $1.key }
                if groups.isEmpty { empty }
                ForEach(groups, id: \.key) { name, list in line(name, list) }
            }
            Section(tr("按对话", "By conversation")) {
                let groups = Dictionary(grouping: rows, by: { $0.session }).sorted { sum($0.value) > sum($1.value) }
                if groups.isEmpty { empty }
                ForEach(groups.prefix(15), id: \.key) { id, list in line(title(id), list) }
            }
            Section(tr("额度与剩余次数", "Quota and remaining limits")) {
                if store.lastHeaderNames.isEmpty && store.limitHeaders.isEmpty {
                    Text(tr("还没有收到过 API 回复。发一条消息后，这里会说明接口是否返回了额度信息。",
                            "No API response yet. After you send a message this shows whether the API returned any quota data."))
                        .font(Theme.ui(12)).foregroundStyle(.secondary)
                } else if store.limitHeaders.isEmpty {
                    Text(tr("xAI 的接口没有返回额度或剩余次数（最近一次回复里没有 rate-limit 类响应头），所以这里不显示额度。超出额度时，对话里会直接显示接口的报错。",
                            "The xAI API did not return quota or remaining-limit data (no rate-limit headers on the latest response), so no quota is shown here. If you hit a limit, the API's error shows in the chat."))
                        .font(Theme.ui(12)).foregroundStyle(.secondary)
                } else {
                    ForEach(store.limitHeaders.sorted { $0.key < $1.key }, id: \.key) { key, value in
                        LabeledContent(key, value: value).font(Theme.mono(11))
                    }
                    if let at = store.limitHeadersAt {
                        Text(tr("取自 \(at.formatted(date: .abbreviated, time: .shortened)) 的接口响应头", "From API response headers at \(at.formatted(date: .abbreviated, time: .shortened))"))
                            .font(Theme.ui(11)).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button(tr("清空用量记录", "Clear usage history"), role: .destructive) { store.clear() }
                    .disabled(store.records.isEmpty)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var empty: some View {
        Text(tr("这段时间没有记录。", "Nothing recorded in this period.")).font(Theme.ui(12)).foregroundStyle(.secondary)
    }

    private func sum(_ list: [UsageRecord]) -> Int { list.reduce(0) { $0 + $1.total } }

    private func title(_ id: UUID?) -> String {
        guard let id else { return tr("（无对话）", "(no conversation)") }
        return model.sessions.first { $0.id == id }?.title ?? tr("已删除的对话", "Deleted conversation")
    }

    private func line(_ name: String, _ list: [UsageRecord]) -> some View {
        LabeledContent(name) {
            Text("\(list.count) " + tr("次", "calls") + " · " + fmt(sum(list)) + " tokens")
                .font(Theme.mono(11))
        }
    }

    @ViewBuilder
    private func totals(_ list: [UsageRecord]) -> some View {
        let input = list.reduce(0) { $0 + $1.input }
        let cached = list.reduce(0) { $0 + $1.cached }
        let output = list.reduce(0) { $0 + $1.output }
        let reasoning = list.reduce(0) { $0 + $1.reasoning }
        LabeledContent(tr("请求", "Requests"), value: "\(list.count)")
        LabeledContent(tr("输入 tokens", "Input tokens"), value: fmt(input) + (cached > 0 ? tr("（缓存 \(fmt(cached))）", " (cached \(fmt(cached)))") : ""))
        LabeledContent(tr("输出 tokens", "Output tokens"), value: fmt(output) + (reasoning > 0 ? tr("（推理 \(fmt(reasoning))）", " (reasoning \(fmt(reasoning)))") : ""))
        LabeledContent(tr("合计 tokens", "Total tokens"), value: fmt(sum(list)))
        let priced = list.compactMap(\.costTicks)
        if !priced.isEmpty {
            LabeledContent(tr("费用（接口报告）", "Cost (reported by API)"),
                           value: String(format: "$%.4f", Double(priced.reduce(0, +)) / 1e10) + (priced.count < list.count ? tr("（部分请求没报费用）", " (some requests had no cost)") : ""))
        }
    }

    private func fmt(_ n: Int) -> String { n.formatted(.number) }
}
