import Foundation

// MARK: - 文本编码

/// 应用支持的文本编码。所有打开的文件先经 `TextCodec.detect` 识别,保存时按标签记录的编码写回。
public enum TextEncoding: String, Codable, CaseIterable {
    case utf8
    case utf8BOM
    case utf16LE
    case utf16BE
    case latin1
    case gb18030

    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf8BOM: return "UTF-8 BOM"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .latin1: return "Latin-1 (ANSI)"
        case .gb18030: return "GB18030 (简体中文)"
        }
    }

    public var swiftEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .utf8BOM: return .utf8
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .latin1: return .isoLatin1
        case .gb18030: return TextCodec.gb18030Encoding
        }
    }
}

/// 编码检测与编解码工具。
public enum TextCodec {

    /// GB18030 编码(通过 CoreFoundation 常量获取,避免硬编码 rawValue)。
    public static let gb18030Encoding: String.Encoding = {
        let cfEnc = CFStringEncodings.GB_18030_2000.rawValue
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEnc))
        return String.Encoding(rawValue: nsEnc)
    }()

    public struct Detection {
        public let encoding: TextEncoding
        public let string: String
    }

    /// 启发式编码检测:BOM 优先 → UTF-8 严格校验 → GB18030 严格校验(含中日韩字符加权)→ Latin-1 兜底。
    public static func detect(_ data: Data) -> Detection {
        let bytes = [UInt8](data)

        // 1. BOM 检测
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            let body = data.dropFirst(3)
            if let s = String(data: body, encoding: .utf8) {
                return Detection(encoding: .utf8BOM, string: s)
            }
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE,
           let s = String(data: data, encoding: .utf16LittleEndian) {
            return Detection(encoding: .utf16LE, string: stripBOM(s))
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF,
           let s = String(data: data, encoding: .utf16BigEndian) {
            return Detection(encoding: .utf16BE, string: stripBOM(s))
        }

        // 2. UTF-8 严格解码(纯 ASCII 与绝大多数现代文件命中此处)
        if let s = String(data: data, encoding: .utf8) {
            return Detection(encoding: .utf8, string: s)
        }

        // 3. GB18030 严格解码:严格模式失败会返回 nil,成功且包含 CJK 字符才采信
        if let s = String(data: data, encoding: gb18030Encoding), !s.contains("\u{FFFD}") {
            if containsCJK(s) {
                return Detection(encoding: .gb18030, string: s)
            }
        }

        // 4. Latin-1 永不失败,作最后兜底
        let s = String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        return Detection(encoding: .latin1, string: s)
    }

    public static func decode(_ data: Data, encoding: TextEncoding) -> String? {
        if encoding == .utf8BOM {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if encoding == .utf16LE || encoding == .utf16BE {
            guard let s = String(data: data, encoding: encoding.swiftEncoding) else { return nil }
            return stripBOM(s)
        }
        return String(data: data, encoding: encoding.swiftEncoding)
    }

    /// 按指定编码把字符串编码为待写盘数据(含 BOM 处理)。编码失败返回 nil(存在无法表示的字符)。
    public static func encode(_ string: String, encoding: TextEncoding) -> Data? {
        switch encoding {
        case .utf8:
            return string.data(using: .utf8)
        case .utf8BOM:
            var d = Data([0xEF, 0xBB, 0xBF])
            d.append(string.data(using: .utf8) ?? Data())
            return d
        case .utf16LE:
            var d = Data([0xFF, 0xFE])
            if let body = string.data(using: .utf16LittleEndian) { d.append(body) }
            return d
        case .utf16BE:
            var d = Data([0xFE, 0xFF])
            if let body = string.data(using: .utf16BigEndian) { d.append(body) }
            return d
        case .latin1, .gb18030:
            return string.data(using: encoding.swiftEncoding)
        }
    }

    /// 编码是否能无损表示该字符串。
    public static func canRepresent(_ string: String, encoding: TextEncoding) -> Bool {
        encode(string, encoding: encoding) != nil
    }

    // MARK: 私有

    private static func stripBOM(_ s: String) -> String {
        s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
    }

    private static func containsCJK(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v)      // CJK 统一表意文字
                || (0x3040...0x30FF).contains(v)  // 日文假名
                || (0xAC00...0xD7AF).contains(v)  // 韩文
                || (0x3000...0x303F).contains(v)  // CJK 标点
                || (0xFF00...0xFFEF).contains(v) { // 全角字符
                return true
            }
        }
        return false
    }
}

// MARK: - 换行符

/// 行结束符。编辑器内部统一使用 LF(\n),打开时检测并记录,保存时按标签属性写回 —— 与 Notepad++ 行为一致。
public enum LineEnding: String, Codable, CaseIterable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"

    public var displayName: String {
        switch self {
        case .lf: return "LF (macOS / Unix)"
        case .crlf: return "CRLF (Windows)"
        case .cr: return "CR (经典 Mac)"
        }
    }

    public var sequence: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }
}

public enum LineEndingTool {

    /// 统计三种行尾出现次数,取最多者;无行尾时默认 LF。
    public static func detect(_ s: String) -> LineEnding {
        var lf = 0, crlf = 0, cr = 0
        let units = Array(s.utf16)
        var i = 0
        while i < units.count {
            if units[i] == 13 {
                if i + 1 < units.count, units[i + 1] == 10 {
                    crlf += 1
                    i += 2
                    continue
                }
                cr += 1
            } else if units[i] == 10 {
                lf += 1
            }
            i += 1
        }
        let maxCount = max(lf, crlf, cr)
        if maxCount == 0 { return .lf }
        if crlf == maxCount { return .crlf }
        if cr == maxCount && cr > lf { return .cr }
        return .lf
    }

    /// 把 \r\n 与孤立 \r 全部归一化为 \n。
    /// 注意:不能用 String.contains("\r") —— 新版 Swift 中 "\r\n" 是单一字素簇,
    /// 按 Character 比较找不到单独的 "\r",必须用 UTF-16 码元级检查。
    public static func normalizeToLF(_ s: String) -> String {
        let units = Array(s.utf16)
        guard units.contains(13) else { return s }
        var result = String()
        result.reserveCapacity(units.count)
        var i = 0
        while i < units.count {
            if units[i] == 13 {
                if i + 1 < units.count, units[i + 1] == 10 {
                    result.append("\n")
                    i += 2
                    continue
                }
                result.append("\n")
                i += 1
                continue
            }
            result.unicodeScalars.append(Unicode.Scalar(units[i]) ?? " ")
            i += 1
        }
        return result
    }

    /// 把内部文本(LF)转换为指定行尾,用于写盘。
    public static func apply(_ s: String, _ ending: LineEnding) -> String {
        guard ending != .lf else { return s }
        return s.replacingOccurrences(of: "\n", with: ending.sequence)
    }
}
