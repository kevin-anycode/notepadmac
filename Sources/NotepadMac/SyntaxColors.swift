import AppKit
import NotepadCore

// MARK: - 语法配色(跟随深浅色模式,Notepad++ 风格调色)

enum SyntaxPalette {
    static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(calibratedRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
        }
    }

    static let keyword = dynamic(light: (0, 0, 255), dark: (86, 156, 214))
    static let string = dynamic(light: (163, 21, 21), dark: (206, 145, 120))
    static let comment = dynamic(light: (0, 128, 0), dark: (87, 166, 74))
    static let number = dynamic(light: (175, 0, 219), dark: (220, 130, 220))
    static let preprocessor = dynamic(light: (127, 0, 127), dark: (197, 134, 192))
    static let tag = dynamic(light: (0, 0, 255), dark: (86, 156, 214))
    static let attribute = dynamic(light: (240, 60, 60), dark: (156, 220, 254))
    static let heading = dynamic(light: (0, 90, 200), dark: (86, 156, 214))
    static let key = dynamic(light: (120, 0, 160), dark: (156, 220, 254))
    static let variable = dynamic(light: (150, 80, 0), dark: (220, 170, 100))

    /// 查找全部匹配的背景高亮
    static let matchHighlight = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.95, green: 0.75, blue: 0.15, alpha: 0.35)
            : NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.3, alpha: 0.9)
    }
}

extension SyntaxHighlighter {

    /// token → NSAttributedString 属性。
    static func attributes(for token: Token, baseFont: NSFont) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [:]
        let color: NSColor
        switch token.kind {
        case .keyword: color = SyntaxPalette.keyword
        case .string: color = SyntaxPalette.string
        case .comment: color = SyntaxPalette.comment
        case .number: color = SyntaxPalette.number
        case .preprocessor: color = SyntaxPalette.preprocessor
        case .tag: color = SyntaxPalette.tag
        case .attribute: color = SyntaxPalette.attribute
        case .heading: color = SyntaxPalette.heading
        case .key: color = SyntaxPalette.key
        case .variable: color = SyntaxPalette.variable
        }
        attrs[.foregroundColor] = color
        if token.italic { attrs[.obliqueness] = 0.25 }
        if token.bold {
            let bold = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
            attrs[.font] = bold
        }
        return attrs
    }
}
