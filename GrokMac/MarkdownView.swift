import AppKit
import SwiftUI

struct MarkdownView: View {
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let value):
                    Text(markdown(value))
                        .font(Theme.prose())
                        .lineSpacing(Theme.proseLineSpacing)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .heading(let level, let value):
                    Text(markdown(value))
                        .font(Theme.proseHeading(level: level))
                        .textSelection(.enabled)
                        .padding(.top, 4)
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
                    .font(Theme.ui(14))
                    .foregroundStyle(Theme.fg2)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Label(copied ? tr("已复制", "Copied") : tr("复制", "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Theme.ui(13, .medium))
                        .foregroundStyle(Theme.fg2)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .frame(height: 40)
            .background(Theme.codeHeader)
            Group {
                if Prefs.shared.codeWrap {
                    codeText
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    ScrollView(.horizontal) {
                        codeText
                            .fixedSize()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }
            .background(Theme.codeBody)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border1, lineWidth: 1))
    }

    private var codeText: some View {
        Text(code)
            .font(Theme.mono(13.5))
            .lineSpacing(Theme.scaled(4))
            .foregroundStyle(Theme.fg1)
            .textSelection(.enabled)
    }
}

private enum Block {
    case prose(String)
    case heading(Int, String)
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
        if let heading = headingLine(lines[index]) {
            output.append(heading)
            index += 1
            continue
        }
        var prose: [String] = []
        while index < lines.count, !lines[index].hasPrefix("```"), headingLine(lines[index]) == nil {
            prose.append(lines[index])
            index += 1
        }
        let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { output.append(.prose(text)) }
    }
    if output.isEmpty, !source.isEmpty { output.append(.prose(source)) }
    return output
}

private func headingLine(_ line: String) -> Block? {
    let hashes = line.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
    return .heading(hashes, String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
}

private func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(text)
}
