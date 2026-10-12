import SwiftUI

/// The pending approval or question. Inline in the chat stream under its tool card,
/// or at the bottom of non-chat pages.
struct GateBar: View {
    var inline = false
    @Environment(AppModel.self) private var model
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.gateTitle)
                .font(Theme.ui(14, .semibold))
                .foregroundStyle(Theme.fg1)
            Text(model.gateDetail)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.fg2)
                .lineLimit(8)
                .textSelection(.enabled)
            if model.gateKind == "ask" {
                TextField("回答", text: $answer)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Spacer()
                    GateButton(title: "跳过", filled: false) { model.decide("no") }
                    GateButton(title: "回答", filled: true) { model.decide(answer) }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                HStack(spacing: 8) {
                    Spacer()
                    GateButton(title: "拒绝", filled: false) { model.decide("no") }
                    if model.gateKind.hasPrefix("approve-mcp:") {
                        GateButton(title: "始终允许此服务器", filled: false) { model.decide("always") }
                    }
                    GateButton(title: "允许", filled: true) { model.decide("yes") }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(inline ? Theme.surface1 : Theme.base, in: RoundedRectangle(cornerRadius: inline ? 16 : 0, style: .continuous))
        .overlay {
            if inline {
                RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.border2, lineWidth: 1)
            }
        }
    }
}

private struct GateButton: View {
    var title: String
    var filled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.ui(13, .medium))
                .foregroundStyle(filled ? Theme.buttonFilledFg : Theme.fg1)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Capsule().fill(filled ? Theme.buttonFilled : Color.clear))
                .overlay(Capsule().stroke(filled ? Color.clear : Theme.border2, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
