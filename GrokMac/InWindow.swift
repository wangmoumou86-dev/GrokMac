import AppKit
import SwiftUI
import WebKit

/// Runs open/save panels as sheets attached to the app's window instead of free-floating panels.
@MainActor
enum AttachedPanel {
    static func present(_ panel: NSSavePanel, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(panel.runModal())
        }
    }
}

/// A link viewer shown as a sheet inside the main window, so sources and links do not jump to another app.
struct WebSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(url.host() ?? url.absoluteString)
                    .font(Theme.ui(13, .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(tr("在浏览器中打开", "Open in browser")) {
                    NSWorkspace.shared.open(url)
                    dismiss()
                }
                Button(tr("完成", "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            WebView(url: url)
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 520, idealHeight: 640)
        .background(Theme.base)
    }
}

private struct WebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// Settings presented as a sheet on the main window instead of a separate Settings window.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SettingsView()
            HStack {
                Spacer()
                Button(tr("完成", "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .background(Theme.base)
        }
    }
}
