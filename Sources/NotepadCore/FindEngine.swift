import Foundation

/// 查找引擎:纯逻辑,可单元测试。所有 range 均为 UTF-16 坐标(与 NSTextStorage 一致)。
public struct FindEngine {

    public struct Options {
        public var query: String
        public var regex: Bool
        public var caseSensitive: Bool

        public init(query: String, regex: Bool = false, caseSensitive: Bool = false) {
            self.query = query
            self.regex = regex
            self.caseSensitive = caseSensitive
        }
    }

    /// 返回文本中全部匹配范围。
    public static func matches(in text: String, options: Options) -> [NSRange] {
        let query = options.query
        guard !query.isEmpty else { return [] }
        let nsText = text as NSString
        var results: [NSRange] = []

        if options.regex {
            var opts: NSRegularExpression.Options = [.anchorsMatchLines]
            if !options.caseSensitive { opts.insert(.caseInsensitive) }
            guard let re = try? NSRegularExpression(pattern: query, options: opts) else { return [] }
            let range = NSRange(location: 0, length: nsText.length)
            re.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                if let m = match, m.range.location != NSNotFound, m.range.length > 0 {
                    results.append(m.range)
                }
            }
        } else {
            var searchRange = NSRange(location: 0, length: nsText.length)
            let searchOpts: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
            while searchRange.location < nsText.length {
                let found = nsText.range(of: query, options: searchOpts, range: searchRange)
                guard found.location != NSNotFound else { break }
                results.append(found)
                searchRange.location = found.location + max(found.length, 1)
                searchRange.length = nsText.length - searchRange.location
            }
        }
        return results
    }

    /// 全部替换:返回(替换后的新文本, 替换次数)。正则替换支持 $n 反向引用。
    public static func replaceAll(in text: String, options: Options, template: String) -> (String, Int) {
        guard !options.query.isEmpty else { return (text, 0) }
        if options.regex {
            var opts: NSRegularExpression.Options = [.anchorsMatchLines]
            if !options.caseSensitive { opts.insert(.caseInsensitive) }
            guard let re = try? NSRegularExpression(pattern: options.query, options: opts) else {
                return (text, 0)
            }
            let nsText = text as NSString
            let full = NSRange(location: 0, length: nsText.length)
            let count = re.numberOfMatches(in: text, options: [], range: full)
            guard count > 0 else { return (text, 0) }
            let result = re.stringByReplacingMatches(
                in: text, options: [], range: full, withTemplate: template)
            return (result, count)
        }
        // 普通文本:倒序逐个替换
        let matches = matches(in: text, options: options)
        guard !matches.isEmpty else { return (text, 0) }
        let result = NSMutableString(string: text)
        for m in matches.reversed() {
            result.replaceCharacters(in: m, with: template)
        }
        return (result as String, matches.count)
    }
}
