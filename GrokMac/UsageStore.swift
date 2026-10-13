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
    /// grok.com's own rate-limit endpoint, tried with the app's sign-in token. nil until tried.
    private(set) var grokCom: GrokComLimit?
    private(set) var grokComStatus: String = ""

    struct GrokComLimit: Equatable { var remaining: Int; var total: Int; var windowSeconds: Int }

    /// Asks grok.com/rest/rate-limits with the app's bearer token. Shows only what it actually returns.
    func probeGrokCom() async {
        let token = await TokenStore.valid()
        guard !token.isEmpty else { grokComStatus = "no token"; return }
        var request = URLRequest(url: URL(string: "https://grok.com/rest/rate-limits")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["requestKind": "DEFAULT", "modelName": "grok-4"])
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            grokComStatus = "HTTP \(status)"
            if status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let total = (json["totalQueries"] as? NSNumber)?.intValue, total > 0,
               let remaining = (json["remainingQueries"] as? NSNumber)?.intValue {
                grokCom = GrokComLimit(remaining: remaining, total: total, windowSeconds: (json["windowSizeSeconds"] as? NSNumber)?.intValue ?? 0)
            } else {
                grokCom = nil
            }
        } catch {
            grokComStatus = error.localizedDescription
            grokCom = nil
        }
        NSLog("GrokMac usage probe grok.com/rest/rate-limits: %@", grokComStatus)
    }

    /// Fraction used from a limit/remaining header pair, when both are present and valid.
    func headerFraction(_ kind: String) -> (used: Double, remaining: Int, limit: Int)? {
        guard let limit = Int(limitHeaders["x-ratelimit-limit-\(kind)"] ?? ""), limit > 0,
              let remaining = Int(limitHeaders["x-ratelimit-remaining-\(kind)"] ?? "") else { return nil }
        return (Double(limit - remaining) / Double(limit), remaining, limit)
    }

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

/// Settings → 用量: a few progress rows like grok.com's usage page; the token ledger sits behind 详情.
struct UsageSettings: View {
    @Environment(AppModel.self) private var model
    @State private var store = UsageStore.shared
    @State private var range = 0
    @State private var details = false

    private var days: Int { [1, 7, 30][range] }
    private var since: Date {
        days == 1 ? Calendar.current.startOfDay(for: .now) : Calendar.current.date(byAdding: .day, value: -days, to: .now)!
    }
    private var rows: [UsageRecord] { store.records.filter { $0.date >= since } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group(tr("xAI API 限额", "xAI API limits"), note: store.limitHeadersAt.map { tr("取自 \($0.formatted(date: .omitted, time: .shortened)) 的 API 回复", "From the API reply at \($0.formatted(date: .omitted, time: .shortened))") }) {
                    meter(tr("请求次数", "Requests"), store.headerFraction("requests"))
                    meter("Tokens", store.headerFraction("tokens"))
                }
                group(tr("grok.com 限额", "grok.com limit")) {
                    if let limit = store.grokCom {
                        let used = Double(limit.total - limit.remaining) / Double(limit.total)
                        meter(tr("对话次数", "Queries"), (used, limit.remaining, limit.total),
                              reset: limit.windowSeconds > 0 ? tr("每 \(limit.windowSeconds / 60) 分钟窗口", "\(limit.windowSeconds / 60)-minute window") : nil)
                    } else {
                        meter(tr("每周 SuperGrok 限额", "Weekly SuperGrok limit"), nil)
                    }
                }
                DisclosureGroup(tr("详情", "Details"), isExpanded: $details) { ledger.padding(.top, 8) }
                    .font(Theme.ui(13))
            }
            .padding(20)
        }
        .task { await store.probeGrokCom() }
    }

    private func group<Content: View>(_ title: String, note: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.ui(13, .semibold))
                Spacer()
                if let note { Text(note).font(Theme.ui(11)).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.fg1.opacity(0.12)))
        }
    }

    /// One grok.com-style row: big percentage used, reset on the right, a bar underneath.
    private func meter(_ label: String, _ value: (used: Double, remaining: Int, limit: Int)?, reset: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(Theme.ui(12)).foregroundStyle(.secondary)
                Spacer()
                Text(tr("重置 ", "Resets ") + (reset ?? tr("暂无数据", "No data")))
                    .font(Theme.ui(12)).foregroundStyle(.secondary)
            }
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(percent(value.used)).font(Theme.ui(20, .semibold)).monospacedDigit()
                    Text(tr("已使用", "used")).font(Theme.ui(12)).foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fg1.opacity(0.12))
                        Capsule().fill(Theme.link).frame(width: max(value.used > 0 ? 4 : 0, geo.size.width * min(value.used, 1)))
                    }
                }
                .frame(height: 8)
            } else {
                Text(tr("暂无数据", "No data")).font(Theme.ui(20, .semibold)).foregroundStyle(.secondary)
            }
        }
    }

    /// As precise as the integers allow: enough decimals that one request or token still shows.
    private func percent(_ used: Double) -> String {
        let p = used * 100
        if p == 0 || p == 100 { return String(format: "%.0f%%", p) }
        return String(format: p < 0.01 ? "%.4f%%" : "%.2f%%", p)
    }

    private var ledger: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $range) {
                Text(tr("今天", "Today")).tag(0)
                Text(tr("7 天", "7 days")).tag(1)
                Text(tr("30 天", "30 days")).tag(2)
            }
            .pickerStyle(.segmented).labelsHidden()
            totals(rows)
            Divider()
            ForEach(Dictionary(grouping: rows, by: \.model).sorted { $0.key < $1.key }, id: \.key) { name, list in line(name, list) }
            Divider()
            ForEach(Dictionary(grouping: rows, by: { $0.session }).sorted { sum($0.value) > sum($1.value) }.prefix(15), id: \.key) { id, list in line(title(id), list) }
            if !store.grokComStatus.isEmpty {
                LabeledContent("grok.com/rest/rate-limits", value: store.grokComStatus).font(Theme.mono(11))
            }
            Button(tr("清空用量记录", "Clear usage history"), role: .destructive) { store.clear() }
                .disabled(store.records.isEmpty)
        }
        .font(Theme.ui(12))
    }

    private func sum(_ list: [UsageRecord]) -> Int { list.reduce(0) { $0 + $1.total } }

    private func title(_ id: UUID?) -> String {
        guard let id else { return tr("（无对话）", "(no conversation)") }
        return model.sessions.first { $0.id == id }?.title ?? tr("已删除的对话", "Deleted conversation")
    }

    private func line(_ name: String, _ list: [UsageRecord]) -> some View {
        LabeledContent(name) {
            Text("\(list.count) " + tr("次", "calls") + " · " + fmt(sum(list)) + " tokens").font(Theme.mono(11))
        }
    }

    @ViewBuilder
    private func totals(_ list: [UsageRecord]) -> some View {
        let input = list.reduce(0) { $0 + $1.input }
        let output = list.reduce(0) { $0 + $1.output }
        LabeledContent(tr("请求", "Requests"), value: "\(list.count)")
        LabeledContent(tr("输入 / 输出 tokens", "Input / output tokens"), value: fmt(input) + " / " + fmt(output))
        let priced = list.compactMap(\.costTicks)
        if !priced.isEmpty {
            LabeledContent(tr("费用", "Cost"), value: String(format: "$%.4f", Double(priced.reduce(0, +)) / 1e10))
        }
    }

    private func fmt(_ n: Int) -> String { n.formatted(.number) }
}
