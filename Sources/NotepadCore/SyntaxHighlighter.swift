import Foundation

// MARK: - 语言定义

/// 支持的编程语言。按扩展名自动识别,也可在"语言"菜单手动切换。
public enum ProgLanguage: String, Codable, CaseIterable {
    case plain
    case markdown
    case json
    case python
    case javascript
    case swift
    case ccpp
    case html
    case xml
    case shell
    case yaml
    case java

    public var displayName: String {
        switch self {
        case .plain: return "纯文本"
        case .markdown: return "Markdown"
        case .json: return "JSON"
        case .python: return "Python"
        case .javascript: return "JavaScript / TypeScript"
        case .swift: return "Swift"
        case .ccpp: return "C / C++"
        case .html: return "HTML"
        case .xml: return "XML"
        case .shell: return "Shell"
        case .yaml: return "YAML"
        case .java: return "Java"
        }
    }

    /// 扩展名 → 语言 映射(小写)。
    public static func detect(fromFileName name: String) -> ProgLanguage {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "md", "markdown": return .markdown
        case "json": return .json
        case "py", "pyw": return .python
        case "js", "mjs", "cjs", "ts", "jsx", "tsx": return .javascript
        case "swift": return .swift
        case "c", "h", "cpp", "hpp", "cc", "hh", "cxx", "hxx": return .ccpp
        case "html", "htm", "vue": return .html
        case "xml", "plist": return .xml
        case "sh", "bash", "zsh": return .shell
        case "yaml", "yml": return .yaml
        case "java": return .java
        default: return .plain
        }
    }
}


// MARK: - 高亮引擎

/// 基于规则(注释 / 字符串 / 关键字 / 数字…)的轻量高亮器。
/// 设计:对整段文本跑若干正则,按"块区域 → 行模式 → 关键字 → 数字"的优先级打标,
/// 已被占用的区间不再被低优先级规则覆盖。
public struct SyntaxHighlighter {

    public enum TokenKind {
        case keyword, string, comment, number, preprocessor, tag, attribute, heading, key, variable
    }

    public struct Token {
        public let kind: TokenKind
        public let bold: Bool
        public let italic: Bool

        public init(_ kind: TokenKind, bold: Bool = false, italic: Bool = false) {
            self.kind = kind
            self.bold = bold
            self.italic = italic
        }
    }

    /// 一种语言的高亮规则集。
    public struct Spec {
        /// (起始, 结束, token) 跨行块:块注释、三引号字符串、模板字符串等
        public var blocks: [(String, String, Token)] = []
        /// 行级正则 → token
        public var patterns: [(String, Token)] = []
        /// 关键字集合(以 \b 包裹做单词匹配)
        public var keywords: Set<String> = []
        /// 是否高亮数字
        public var numbers: Bool = true
    }

    /// 超过此大小(字节)的文件自动降级为纯文本,避免卡顿。
    public static let highlightSizeLimit = 1_000_000

    public static func spec(for language: ProgLanguage) -> Spec {
        switch language {
        case .plain:
            return Spec(numbers: false)

        case .markdown:
            var spec = Spec()
            spec.blocks = [("```", "```", Token(.string))]
            spec.patterns = [
                ("^#{1,6}[ \\t].*$", Token(.heading, bold: true)),
                ("^>[ \\t]?.*$", Token(.comment, italic: true)),
                ("^[ \\t]*([-*+]|\\d+\\.)[ \\t]", Token(.keyword, bold: true)),
                ("\\*\\*[^*\n]+\\*\\*", Token(.heading, bold: true)),
                ("(?<!\\*)\\*[^*\n]+\\*(?!\\*)", Token(.attribute, italic: true)),
                ("`[^`\n]+`", Token(.string)),
                ("\\[[^\\]]*\\]\\([^)]*\\)", Token(.key)),
                ("^(-{3,}|={3,})\\s*$", Token(.keyword)),
            ]
            spec.numbers = false
            return spec

        case .json:
            var spec = Spec()
            spec.blocks = []
            spec.patterns = [
                ("\"(\\\\.|[^\"\\\\])*\"(?=\\s*:)", Token(.key)),
                ("\"(\\\\.|[^\"\\\\])*\"", Token(.string)),
                ("\\b(true|false|null)\\b", Token(.keyword, bold: true)),
            ]
            return spec

        case .python:
            var spec = Spec()
            spec.blocks = [("\"\"\"", "\"\"\"", Token(.string)),
                           ("'''", "'''", Token(.string))]
            spec.patterns = [
                ("#[^\n]*", Token(.comment, italic: true)),
                ("@\\w+", Token(.preprocessor)),
                ("\\b\\d+\\.?\\d*\\b", Token(.number)),
            ]
            spec.keywords = ["and", "as", "assert", "async", "await", "break", "class", "continue",
                             "def", "del", "elif", "else", "except", "finally", "for", "from",
                             "global", "if", "import", "in", "is", "lambda", "nonlocal", "not",
                             "or", "pass", "raise", "return", "try", "while", "with", "yield",
                             "True", "False", "None", "self"]
            return spec

        case .javascript:
            var spec = Spec()
            spec.blocks = [("/*", "*/", Token(.comment, italic: true)),
                           ("`", "`", Token(.string))]
            spec.patterns = [
                ("//[^\n]*", Token(.comment, italic: true)),
                ("'(\\\\.|[^'\\\\\\n])*'", Token(.string)),
                ("\"(\\\\.|[^\"\\\\\\n])*\"", Token(.string)),
                ("\\b0x[0-9a-fA-F]+\\b|\\b\\d+\\.?\\d*\\b", Token(.number)),
            ]
            spec.keywords = ["async", "await", "break", "case", "catch", "class", "const",
                             "continue", "debugger", "default", "delete", "do", "else", "export",
                             "extends", "finally", "for", "function", "if", "import", "in",
                             "instanceof", "interface", "let", "new", "of", "return", "static",
                             "super", "switch", "this", "throw", "try", "typeof", "var", "void",
                             "while", "with", "yield", "true", "false", "null", "undefined"]
            return spec

        case .swift:
            var spec = Spec()
            spec.blocks = [("/*", "*/", Token(.comment, italic: true))]
            spec.patterns = [
                ("//[^\n]*", Token(.comment, italic: true)),
                ("\"(\\\\.|[^\"\\\\\\n])*\"", Token(.string)),
                ("@\\w+", Token(.preprocessor)),
                ("\\b0x[0-9a-fA-F]+\\b|\\b\\d[\\d_]*\\.?\\d*\\b", Token(.number)),
            ]
            spec.keywords = ["actor", "associatedtype", "as", "async", "await", "break", "case",
                             "catch", "class", "continue", "default", "defer", "deinit", "do",
                             "dynamic", "else", "enum", "extension", "fallthrough", "final",
                             "for", "func", "get", "guard", "if", "import", "in", "inout",
                             "internal", "is", "lazy", "let", "nil", "open", "operator",
                             "private", "protocol", "public", "repeat", "required", "rethrows",
                             "return", "self", "set", "some", "static", "struct", "subscript",
                             "super", "switch", "throw", "throws", "try", "typealias", "var",
                             "where", "while", "willSet", "true", "false", "init"]
            return spec

        case .ccpp:
            var spec = Spec()
            spec.blocks = [("/*", "*/", Token(.comment, italic: true))]
            spec.patterns = [
                ("//[^\n]*", Token(.comment, italic: true)),
                ("'(\\\\.|[^'\\\\\\n])*'", Token(.string)),
                ("\"(\\\\.|[^\"\\\\\\n])*\"", Token(.string)),
                ("^[ \\t]*#[^\n]*", Token(.preprocessor)),
                ("\\b0x[0-9a-fA-F]+\\b|\\b\\d+\\.?\\d*[fuUlL]*\\b", Token(.number)),
            ]
            spec.keywords = ["alignas", "auto", "bool", "break", "case", "catch", "char", "class",
                             "const", "constexpr", "continue", "default", "delete", "do", "double",
                             "else", "enum", "explicit", "export", "extern", "false", "float",
                             "for", "friend", "goto", "if", "inline", "int", "long", "mutable",
                             "namespace", "new", "noexcept", "nullptr", "operator", "private",
                             "protected", "public", "return", "short", "signed", "sizeof",
                             "static", "struct", "switch", "template", "this", "throw", "true",
                             "try", "typedef", "typename", "union", "unsigned", "using",
                             "virtual", "void", "volatile", "while", "override", "final"]
            return spec

        case .java:
            var spec = Spec()
            spec.blocks = [("/*", "*/", Token(.comment, italic: true))]
            spec.patterns = [
                ("//[^\n]*", Token(.comment, italic: true)),
                ("\"(\\\\.|[^\"\\\\\\n])*\"", Token(.string)),
                ("@\\w+", Token(.preprocessor)),
                ("\\b0x[0-9a-fA-F]+\\b|\\b\\d+\\.?\\d*[fFdDlL]?\\b", Token(.number)),
            ]
            spec.keywords = ["abstract", "assert", "boolean", "break", "byte", "case", "catch",
                             "char", "class", "const", "continue", "default", "do", "double",
                             "else", "enum", "extends", "final", "finally", "float", "for",
                             "goto", "if", "implements", "import", "instanceof", "int",
                             "interface", "long", "native", "new", "package", "private",
                             "protected", "public", "return", "short", "static", "strictfp",
                             "super", "switch", "synchronized", "this", "throw", "throws",
                             "transient", "try", "void", "volatile", "while", "true", "false",
                             "null", "record", "var", "sealed", "yield"]
            return spec

        case .html, .xml:
            var spec = Spec()
            spec.blocks = [("<!--", "-->", Token(.comment, italic: true))]
            spec.patterns = [
                ("</?[A-Za-z][\\w:-]*", Token(.tag)),
                ("/?>", Token(.tag)),
                ("\"(\\\\.|[^\"\\\\\\n])*\"", Token(.attribute)),
                ("'[\\w.;#-]*'", Token(.attribute)),
                ("&[a-zA-Z]+;|&#\\d+;", Token(.number)),
            ]
            spec.numbers = false
            return spec

        case .shell:
            var spec = Spec()
            spec.blocks = []
            spec.patterns = [
                ("(?<![$\\w])#[^\n]*", Token(.comment, italic: true)),
                ("'(\\\\.|[^'\\\\\\n])*'", Token(.string)),
                ("\"(\\\\.|[^\"\\\\\\n])*\"", Token(.string)),
                ("\\$\\{[^}\n]*\\}|\\$\\w+", Token(.variable)),
                ("^#!.*$", Token(.preprocessor, bold: true)),
                ("\\b\\d+\\.?\\d*\\b", Token(.number)),
            ]
            spec.keywords = ["if", "then", "else", "elif", "fi", "for", "while", "until", "do",
                             "done", "case", "esac", "in", "function", "select", "break",
                             "continue", "return", "exit", "export", "local", "readonly",
                             "shift", "source", "eval", "exec", "trap", "unset", "alias",
                             "echo", "cd", "true", "false"]
            return spec

        case .yaml:
            var spec = Spec()
            spec.blocks = []
            spec.patterns = [
                ("(?<![$\\w])#[^\n]*", Token(.comment, italic: true)),
                ("^---\\s*$|^\\.\\.\\.\\s*$", Token(.preprocessor, bold: true)),
                ("^[ \\t]*-?[ \\t]*[\\w.\\-/ ]+:(?=\\s)", Token(.key)),
                ("'(\\\\.|[^'\\\\\\n])*'", Token(.string)),
                ("\"(\\\\.|[^\"\\\\\\n])*\"", Token(.string)),
                ("\\b(true|false|null|yes|no|on|off)\\b", Token(.keyword, bold: true)),
                ("\\b\\d+\\.?\\d*\\b", Token(.number)),
            ]
            return spec
        }
    }

    // MARK: 执行高亮

    /// 计算指定语言文本的全部着色区间,返回 (NSRange, Token) 列表。
    public static func tokens(for text: String, language: ProgLanguage) -> [(NSRange, Token)] {
        guard language != .plain, !text.isEmpty else { return [] }
        let spec = spec(for: language)
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        guard full.length > 0 else { return [] }

        // 占用掩码:UTF-16 单元级别
        var occupied = [Bool](repeating: false, count: full.length)
        var results: [(NSRange, Token)] = []

        func claimFree(_ range: NSRange) -> Bool {
            guard range.location != NSNotFound,
                  range.location >= 0,
                  range.location + range.length <= occupied.count else { return false }
            for i in range.location..<(range.location + range.length) where occupied[i] {
                return false
            }
            return true
        }

        func claim(_ range: NSRange) {
            for i in range.location..<(range.location + range.length) {
                occupied[i] = true
            }
        }

        func addRegex(_ pattern: String, _ token: Token, wholeLine: Bool = false) {
            let opts: NSRegularExpression.Options = [.anchorsMatchLines, .dotMatchesLineSeparators]
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return }
            re.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let m = match, m.range.length > 0 else { return }
                if claimFree(m.range) {
                    results.append((m.range, token))
                    claim(m.range)
                }
            }
        }

        // 1. 跨行块(块注释、三引号、反引号模板等)优先级最高
        for (start, end, token) in spec.blocks {
            let s = NSRegularExpression.escapedPattern(for: start)
            let e = NSRegularExpression.escapedPattern(for: end)
            if start == end {
                // 同界符(如 ```、`):非贪婪配对
                addRegex("\(s)((?!\(s)).)*?\(e)", token)
            } else {
                addRegex("\(s)((?!\(s)).)*?\(e)", token)
            }
        }

        // 2. 行级模式(行注释、字符串、预处理器、结构化元素)
        for (pattern, token) in spec.patterns {
            addRegex(pattern, token)
        }

        // 3. 关键字
        if !spec.keywords.isEmpty {
            let escaped = spec.keywords
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .sorted { $0.count > $1.count }
                .joined(separator: "|")
            addRegex("\\b(?:\(escaped))\\b", Token(.keyword, bold: true))
        }

        // 4. 数字
        if spec.numbers {
            addRegex("\\b0x[0-9a-fA-F]+\\b|\\b\\d+\\.?\\d*\\b", Token(.number))
        }

        return results
    }

}
