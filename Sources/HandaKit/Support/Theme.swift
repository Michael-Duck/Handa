import AppKit
import HandaCore

/// Handa's colours and type. The brand runs warm: coral on paper, plum ink.
enum Theme {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }

    // Brand palette
    static let coral = hex(0xF86F5B)
    static let tangerine = hex(0xFFA35C)
    static let rose = hex(0xEC4868)
    static let ink = hex(0x1F1A2E)
    static let accent = dynamic(light: hex(0xE85A47), dark: hex(0xFF8A70))
    static let paperTint = dynamic(light: hex(0xFFF6EF), dark: hex(0x2A2230))

    /// Neutral backdrop behind pages and images.
    static let canvas = dynamic(light: hex(0xE9E6E3), dark: hex(0x1C1A1F))
    static let statusText = NSColor.secondaryLabelColor

    static func monospaced(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func rounded(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    // Syntax colours, close to Xcode's defaults so code looks familiar.
    private static let tokenColors: [TokenKind: NSColor] = [
        .keyword: dynamic(light: hex(0x9B2393), dark: hex(0xFC5FA3)),
        .type: dynamic(light: hex(0x0B4F79), dark: hex(0x5DD8FF)),
        .function: dynamic(light: hex(0x326D74), dark: hex(0x67B7A4)),
        .string: dynamic(light: hex(0xC41A16), dark: hex(0xFC6A5D)),
        .number: dynamic(light: hex(0x1C00CF), dark: hex(0xD0BF69)),
        .comment: dynamic(light: hex(0x5D6C79), dark: hex(0x7F8C98)),
        .attribute: dynamic(light: hex(0x815F03), dark: hex(0xFD8F3F)),
        .tag: dynamic(light: hex(0x9B2393), dark: hex(0xFC5FA3)),
        .property: dynamic(light: hex(0x0F68A0), dark: hex(0x41A1C0)),
        .variable: dynamic(light: hex(0x326D74), dark: hex(0x67B7A4)),
        .heading: dynamic(light: hex(0xC24A2E), dark: hex(0xFF8A70)),
        .emphasis: dynamic(light: hex(0x6F42C1), dark: hex(0xC4A7FF)),
        .link: dynamic(light: hex(0x0F68A0), dark: hex(0x41A1C0)),
        .inserted: dynamic(light: hex(0x1A7F37), dark: hex(0x7EE787)),
        .deleted: dynamic(light: hex(0xB31D28), dark: hex(0xFF7B72)),
        .meta: dynamic(light: hex(0x6A737D), dark: hex(0x8B949E)),
    ]

    static func color(for kind: TokenKind) -> NSColor {
        tokenColors[kind] ?? .textColor
    }

    static func codeParagraphStyle(font: NSFont, wraps: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.18
        style.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        let tabWidth = " ".size(withAttributes: [.font: font]).width * 4
        style.defaultTabInterval = tabWidth
        style.tabStops = []
        return style
    }
}
