import SwiftUI
import UIKit

/// Warm, paper-like palette: ivory / charcoal surfaces, terracotta accent, serif headings.
enum Theme {
    static let background = dynamic(light: 0xFAF9F5, dark: 0x262624)
    static let surface = dynamic(light: 0xF0EEE6, dark: 0x30302E)        // cards, user bubbles
    static let raised = dynamic(light: 0xFFFFFF, dark: 0x393937)         // composer, sheets
    static let border = dynamic(light: 0xE3E0D6, dark: 0x4A4945)
    static let text = dynamic(light: 0x1F1E1D, dark: 0xF4F3EE)
    static let secondary = dynamic(light: 0x75736B, dark: 0xA9A69C)
    static let accent = dynamic(light: 0xC96442, dark: 0xD97757)         // terracotta
    static let accentSoft = dynamic(light: 0xF5E3DA, dark: 0x4A3329)
    static let success = dynamic(light: 0x5E8C61, dark: 0x8DBE8F)
    static let warning = dynamic(light: 0xB7791F, dark: 0xE3B05B)

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static let mono = Font.system(.caption, design: .monospaced)
    static let monoSmall = Font.system(.caption2, design: .monospaced)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    /// Serif navigation titles and warm bars, app-wide.
    static func applyAppearance() {
        let text = UIColor(Theme.text)
        func serif(_ style: UIFont.TextStyle, bold: Bool) -> UIFont {
            var d = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style)
            d = d.withDesign(.serif) ?? d
            if bold { d = d.withSymbolicTraits(.traitBold) ?? d }
            return UIFont(descriptor: d, size: 0)
        }
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundColor = UIColor(Theme.background)
        nav.largeTitleTextAttributes = [.font: serif(.largeTitle, bold: false), .foregroundColor: text]
        nav.titleTextAttributes = [.font: serif(.headline, bold: true), .foregroundColor: text]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// Warm background for List/Form screens.
    func themedList() -> some View {
        scrollContentBackground(.hidden).background(Theme.background)
    }

    func card(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .background(Theme.surface, in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.border, lineWidth: 0.5))
    }
}
