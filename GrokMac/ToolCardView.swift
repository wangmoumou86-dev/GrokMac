import SwiftUI

struct ToolCardView: View {
    var tool: ToolTrace
    @State private var expanded: Bool? = nil

    private var statusText: String {
        switch tool.status {
        case "running": "运行中"
        case "approval": "等你批准"
        case "ask": "等你回答"
        case "error": "失败"
        default: "完成"
        }
    }

    private var icon: String {
        switch tool.name {
        case "bash", "run_tests", "open_pr": "terminal"
        case "read_file", "glob", "grep", "codebase_search": "doc.text.magnifyingglass"
        case "write_file", "edit_file", "apply_patch", "undo": "pencil"
        default: "wrench.and.screwdriver"
        }
    }

    var body: some View {
        let open = expanded ?? (tool.status == "running" || tool.status == "approval" || tool.status == "ask")
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded = !open
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: icon)
                        .font(.caption)
                    Text(tool.name == "bash" ? "$ " + tool.input : "\(tool.name)  \(tool.input)")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    if tool.status == "running" {
                        ProgressView().controlSize(.mini)
                    }
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(tool.status == "error" ? Theme.danger : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Text(tool.input)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(12)
                    .textSelection(.enabled)
                if !tool.output.isEmpty {
                    ScrollView {
                        Text(tool.output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 8))
    }
}
