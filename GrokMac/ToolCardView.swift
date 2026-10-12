import SwiftUI

struct ToolCardView: View {
    var tool: ToolTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tool.name)
                    .font(.caption.monospaced())
                Spacer()
                Text(tool.status == "running" ? "运行中" : tool.status == "error" ? "失败" : "完成")
                    .font(.caption)
                    .foregroundStyle(tool.status == "error" ? Color(red: 0.88, green: 0.36, blue: 0.39) : .secondary)
            }
            Text(tool.input)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .textSelection(.enabled)
            if !tool.output.isEmpty {
                Text(tool.output)
                    .font(.caption.monospaced())
                    .lineLimit(12)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
