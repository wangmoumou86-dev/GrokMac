import AppKit
import CoreText
import SwiftUI

/// Semantic colors measured from grok.com (warm grays). Each resolves against the
/// window's effective appearance, so it follows Settings → theme (dark, light, system).
enum Theme {
    static let base = dynamic(light: 0xF9F8F7, dark: 0x131211)
    static let sidebar = dynamic(light: 0xF5F3F2, dark: 0x181716)
    static let surface1 = dynamic(light: 0xF5F3F2, dark: 0x181716)
    static let surface2 = dynamic(light: 0xF0EFED, dark: 0x201F1D)
    static let composer = dynamic(light: 0xFFFFFF, dark: 0x201F1D)
    static let composerBorder = dynamic(light: 0xE6E5E3, dark: 0xFCFCFC, darkAlpha: 0.06)
    static let userBubble = dynamic(light: 0xF0EFED, dark: 0x201F1D)
    static let codeHeader = dynamic(light: 0xFFFFFF, dark: 0x181716)
    static let codeBody = dynamic(light: 0xFFFFFF, dark: 0x23211F)
    static let border1 = dynamic(light: 0x0F0D0A, lightAlpha: 0.04, dark: 0xFCFCFC, darkAlpha: 0.06)
    static let border2 = dynamic(light: 0x0F0D0A, lightAlpha: 0.08, dark: 0xFCFCFC, darkAlpha: 0.10)
    static let hover = dynamic(light: 0x0F0D0A, lightAlpha: 0.05, dark: 0xFCFCFC, darkAlpha: 0.07)
    static let fg1 = dynamic(light: 0x050505, dark: 0xFCFCFC)
    static let fg2 = dynamic(light: 0x636363, dark: 0x9E9E9E)
    static let fg3 = dynamic(light: 0x858585, dark: 0x858585)
    static let sidebarFg = dynamic(light: 0x3F3F46, dark: 0xF4F4F5)
    static let buttonFilled = dynamic(light: 0x050505, dark: 0xFCFCFC)
    static let buttonFilledFg = dynamic(light: 0xFCFCFC, dark: 0x050505)
    static let buttonDisabled = dynamic(light: 0x0F0D0A, lightAlpha: 0.08, dark: 0xFCFCFC, darkAlpha: 0.10)
    static let link = dynamic(light: 0x3F5FD9, dark: 0x8EA5F0)
    static let danger = dynamic(light: 0xB3242F, dark: 0xE15C64)
    static let scrim = Color.black.opacity(0.94)

    // MARK: Typography
    // Bundled OFL fonts (Fonts/): Inter for UI chrome, Source Serif 4 for reply prose.
    // Code stays SF Mono. Core Text's default cascade falls back to PingFang for CJK.

    static let uiFamily = "Inter"
    static let proseFamily = "Source Serif 4"
    static let proseSize: CGFloat = 16
    static let proseLineSpacing: CGFloat = 8

    /// Registers the bundled fonts for this process only. Call once at launch.
    static func registerFonts() {
        let urls = ["ttf", "otf"].flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    /// Inter at the given size; weights Regular, Medium and SemiBold are bundled.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(uiFamily, size: size).weight(weight)
    }

    /// Source Serif 4 for assistant prose (Regular, Semibold, Italic bundled).
    static func prose(_ size: CGFloat = proseSize, _ weight: Font.Weight = .regular) -> Font {
        .custom(proseFamily, size: size).weight(weight)
    }

    static func proseHeading(level: Int) -> Font {
        prose(level <= 1 ? 22 : level == 2 ? 19 : 17, .semibold)
    }

    static func mono(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }

    /// Measured layout values.
    static let contentWidth: CGFloat = 704
    static let composerWidth: CGFloat = 752

    private static func dynamic(light: UInt32, lightAlpha: CGFloat = 1, dark: UInt32, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light, isDark ? darkAlpha : lightAlpha)
        })
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
}
