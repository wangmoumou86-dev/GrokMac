import AppKit
import SwiftUI

struct MarkdownView: View {
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let value):
                    Text(markdown(value))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let lang, let code):
                    CodeBlock(lang: lang, code: code)
                }
            }
        }
    }
}

private struct CodeBlock: View {
    var lang: String
    var code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? "text" : lang)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? tr("已复制", "Copied") : tr("复制", "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            if Prefs.shared.codeWrap {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            } else {
                ScrollView(.horizontal) {
                    Text(code)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
            }
        }
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12)))
    }
}

private enum Block {
    case prose(String)
    case code(String, String)
}

private func blocks(_ source: String) -> [Block] {
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var output: [Block] = []
    var index = 0
    while index < lines.count {
        if lines[index].hasPrefix("```") {
            let lang = String(lines[index].dropFirst(3)).trimmingCharacters(in: .whitespaces)
            index += 1
            var code: [String] = []
            while index < lines.count, !lines[index].hasPrefix("```") {
                code.append(lines[index])
                index += 1
            }
            if index < lines.count { index += 1 }
            output.append(.code(lang, code.joined(separator: "\n")))
            continue
        }
        var prose: [String] = []
        while index < lines.count, !lines[index].hasPrefix("```") {
            prose.append(lines[index])
            index += 1
        }
        let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { output.append(.prose(text)) }
    }
    if output.isEmpty, !source.isEmpty { output.append(.prose(source)) }
    return output
}

private func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(text)
}
