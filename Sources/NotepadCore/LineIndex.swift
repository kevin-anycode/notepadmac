import Foundation

/// 行号索引:维护每行起始的 UTF-16 偏移(与 NSTextStorage / NSRange 的坐标体系一致)。
/// 供行号标尺、状态栏"行:列"、跳转到行共用。
public struct LineIndex {
    /// lineStarts[i] = 第 i+1 行的起始偏移(始终包含 0)
    public private(set) var lineStarts: [Int] = [0]
    public private(set) var length: Int = 0

    public init() {}

    public init(text: String) {
        rebuild(text: text)
    }

    public var lineCount: Int { lineStarts.count }

    public mutating func rebuild(text: String) {
        var starts: [Int] = [0]
        var offset = 0
        for unit in text.utf16 {
            if unit == 10 { // \n
                starts.append(offset + 1)
            }
            offset += 1
        }
        lineStarts = starts
        length = offset
    }

    /// 返回字符偏移所在的行号(1-based);越界时返回最后一行。
    public func lineNumber(at offset: Int) -> Int {
        guard !lineStarts.isEmpty else { return 1 }
        if offset <= 0 { return 1 }
        if offset >= length { return lineStarts.count }
        // 二分查找:最后一个 <= offset 的起点
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo + 1
    }

    /// 返回某行(1-based)的起始偏移;越界时返回文本末尾。
    public func startOfLine(_ line: Int) -> Int {
        guard line >= 1, line <= lineStarts.count else { return length }
        return lineStarts[line - 1]
    }

    /// 返回某行(1-based)的结束偏移(不含 \n)。
    public func endOfLine(_ line: Int) -> Int {
        if line >= lineStarts.count { return length }
        return startOfLine(line + 1) - 1
    }

    /// 指定偏移处的列号(1-based,以字符计)。
    public func column(at offset: Int) -> Int {
        let line = lineNumber(at: offset)
        return offset - startOfLine(line) + 1
    }

    /// 指定偏移所在行的 NSRange(UTF-16)。
    public func lineRange(containing offset: Int) -> NSRange {
        let line = lineNumber(at: offset)
        let start = startOfLine(line)
        let end = endOfLine(line)
        return NSRange(location: start, length: max(0, end - start))
    }
}
