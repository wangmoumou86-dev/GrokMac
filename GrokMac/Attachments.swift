import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

struct ComposerAttachment: Identifiable, Equatable {
    enum Kind: Equatable { case image, pdf }
    var id = UUID()
    var name: String
    var kind: Kind
    /// JPEG data URL for images; https://docs.x.ai/developers/model-capabilities/images/understanding (jpg/png only).
    var dataURL: String?
    /// Extracted text for PDFs.
    var text: String?

    static let maxPDFChars = 60_000

    static func load(_ url: URL) -> ComposerAttachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url) else { return nil }
            let text = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ComposerAttachment(name: url.lastPathComponent, kind: .pdf, text: String(text.prefix(maxPDFChars)))
        }
        guard let image = NSImage(contentsOf: url), let dataURL = jpegDataURL(image) else { return nil }
        return ComposerAttachment(name: url.lastPathComponent, kind: .image, dataURL: dataURL)
    }

    static func jpegDataURL(_ image: NSImage, maxSide: CGFloat = 1600) -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let width = max(1, Int(CGFloat(cg.width) * scale))
        let height = max(1, Int(CGFloat(cg.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }
}

extension ChatMessage {
    /// Text sent to the model: the visible prompt plus any PDF text.
    var promptText: String {
        guard let context, !context.isEmpty else { return content }
        return content + "\n\n" + context
    }

    var allImages: [String] {
        var list = images ?? []
        if let image, image.hasPrefix("data:image/"), !list.contains(image) { list.insert(image, at: 0) }
        return list
    }
}
