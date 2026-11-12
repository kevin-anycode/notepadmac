// NotepadMac 独立测试运行器
// 背景:仅装 Command Line Tools 的机器没有 XCTest.framework,无法用 `swift test`。
// 本文件把全部单元用例移植为普通函数 + 轻量断言,由 Scripts/run_tests.sh 编译运行。
// 运行:notepadmac-test(退出码 0 = 全部通过)

import Foundation
import AppKit
import NotepadCore

// MARK: - 轻量断言框架

nonisolated(unsafe) var passCount = 0
nonisolated(unsafe) var failCount = 0
nonisolated(unsafe) var currentSuite = ""

func suite(_ name: String) {
    currentSuite = name
    print("\n== \(name) ==")
}

private func report(_ ok: Bool, _ message: String, file: String, line: Int) {
    if ok {
        passCount += 1
        print("  ✓ \(message)")
    } else {
        failCount += 1
        print("  ✗ \(message)  (\((file as NSString).lastPathComponent):\(line))")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String, file: String = #file, line: Int = #line) {
    report(a == b, message, file: file, line: line)
}

func expectTrue(_ cond: Bool, _ message: String, file: String = #file, line: Int = #line) {
    report(cond, message, file: file, line: line)
}

func expectFalse(_ cond: Bool, _ message: String, file: String = #file, line: Int = #line) {
    report(!cond, message, file: file, line: line)
}

// MARK: - 编码检测

func testEncoding() {
    suite("编码检测")

    let chinese = "你好,世界 hello 123"
    let utf8 = TextCodec.detect(chinese.data(using: .utf8)!)
    expectEqual(utf8.encoding, .utf8, "UTF-8 中文识别")
    expectEqual(utf8.string, chinese, "UTF-8 内容无损")

    var bomData = Data([0xEF, 0xBB, 0xBF])
    let bomText = "带 BOM 的中文内容"
    bomData.append(bomText.data(using: .utf8)!)
    let bom = TextCodec.detect(bomData)
    expectEqual(bom.encoding, .utf8BOM, "UTF-8 BOM 识别")
    expectEqual(bom.string, bomText, "BOM 剥离正确")

    var leData = Data([0xFF, 0xFE])
    let leText = "UTF-16 LE 编码测试"
    leData.append(leText.data(using: .utf16LittleEndian)!)
    let le = TextCodec.detect(leData)
    expectEqual(le.encoding, .utf16LE, "UTF-16 LE 识别")
    expectEqual(le.string, leText, "UTF-16 LE 内容无损")

    var beData = Data([0xFE, 0xFF])
    let beText = "UTF-16 BE encoding"
    beData.append(beText.data(using: .utf16BigEndian)!)
    let be = TextCodec.detect(beData)
    expectEqual(be.encoding, .utf16BE, "UTF-16 BE 识别")

    let gbText = "这是一段简体中文内容,用于验证 GB18030 编码检测。"
    let gbData = gbText.data(using: TextCodec.gb18030Encoding)!
    expectFalse(gbData == gbText.data(using: .utf8)!, "GB18030 与 UTF-8 编码不同")
    let gb = TextCodec.detect(gbData)
    expectEqual(gb.encoding, .gb18030, "GB18030 识别")
    expectEqual(gb.string, gbText, "GB18030 内容无损")

    // Latin-1 兜底样本:非法 UTF-8(E9 开头)且 GB18030 解码失败(E9 后第二字节 0x30 非法)
    // 注:不能用 "Héllo"(48 E9 6C 6C 6F)—— 该布局恰好全部落入 GB18030 双字节码位,会误判为中文编码
    let latinData = Data([0xE9, 0x30, 0x6C, 0x6C, 0x6F])
    let latin = TextCodec.detect(latinData)
    expectEqual(latin.encoding, .latin1, "Latin-1 兜底")
    expectEqual(latin.string, "é0llo", "Latin-1 内容正确")

    // 往返:各编码能表示的内容各自往返;不能表示的组合断言返回 nil
    let mixed = "混合内容 English + 中文"
    for enc in TextEncoding.allCases {
        guard let data = TextCodec.encode(mixed, encoding: enc) else {
            expectEqual(enc, TextEncoding.latin1, "Latin-1 无法编码中文(预期)")
            continue
        }
        guard let decoded = TextCodec.decode(data, encoding: enc) else {
            expectTrue(false, "\(enc) 解码失败")
            continue
        }
        expectEqual(decoded, mixed, "\(enc) 往返无损")
    }
    // 含 emoji 的内容仅 UTF-8 / UTF-16 可表示
    let emoji = "emoji 🎉 内容"
    for enc in [TextEncoding.utf8, .utf8BOM, .utf16LE, .utf16BE] {
        guard let data = TextCodec.encode(emoji, encoding: enc),
              let decoded = TextCodec.decode(data, encoding: enc) else {
            expectTrue(false, "\(enc) emoji 编解码失败")
            continue
        }
        expectEqual(decoded, emoji, "\(enc) emoji 往返无损")
    }
    expectFalse(TextCodec.canRepresent(emoji, encoding: .latin1), "Latin-1 不可表示 emoji")

    expectTrue(TextCodec.canRepresent("普通文本", encoding: .utf8), "UTF-8 可表示中文")
    expectFalse(TextCodec.canRepresent("中文", encoding: .latin1), "Latin-1 不可表示中文")
}

// MARK: - 换行符

func testLineEnding() {
    suite("换行符")

    expectEqual(LineEndingTool.detect("a\r\nb\r\nc"), .crlf, "CRLF 检测")
    expectEqual(LineEndingTool.detect("a\nb\nc"), .lf, "LF 检测")
    expectEqual(LineEndingTool.detect("a\rb\rc"), .cr, "CR 检测")
    expectEqual(LineEndingTool.detect("a\r\nb\nc\r\n"), .crlf, "混合行尾取多数")
    expectEqual(LineEndingTool.detect(""), .lf, "空文本默认 LF")
    expectEqual(LineEndingTool.detect("no newline"), .lf, "无行尾默认 LF")

    expectEqual(LineEndingTool.normalizeToLF("a\r\nb\rc\nd"), "a\nb\nc\nd", "归一化到 LF")
    expectEqual(LineEndingTool.normalizeToLF("plain"), "plain", "无行尾不动")

    let original = "line1\nline2\nline3"
    for ending in LineEnding.allCases {
        let applied = LineEndingTool.apply(original, ending)
        expectEqual(LineEndingTool.detect(applied), ending, "\(ending) 应用后检测一致")
        expectEqual(LineEndingTool.normalizeToLF(applied), original, "\(ending) 往返无损")
    }
}

// MARK: - 行索引

func testLineIndex() {
    suite("行索引")

    let sample = "第一行\nsecond\n\n第四行\nend"
    let index = LineIndex(text: sample)
    let ns = sample as NSString

    expectEqual(index.lineCount, 5, "行数 = 5")
    expectEqual(index.lineNumber(at: ns.range(of: "second").location), 2, "second 在第 2 行")
    expectEqual(index.lineNumber(at: 0), 1, "起点在第 1 行")
    expectEqual(index.lineNumber(at: ns.length), 5, "末尾在第 5 行")
    expectEqual(index.lineNumber(at: 9999), 5, "越界安全")
    expectEqual(index.startOfLine(1), 0, "第 1 行起点")
    let secondStart = index.startOfLine(2)
    expectEqual(index.column(at: secondStart), 1, "行首列号 1")
    expectEqual(index.column(at: secondStart + 3), 4, "偏移 3 列号 4")
    let endRange = index.lineRange(containing: ns.range(of: "end").location)
    expectEqual(ns.substring(with: endRange), "end", "行范围提取")
    expectEqual(index.endOfLine(1), 3, "第 1 行结束位置")

    let empty = LineIndex(text: "")
    expectEqual(empty.lineCount, 1, "空文本 1 行")
}

// MARK: - 查找引擎

func testFindEngine() {
    suite("查找引擎")

    let text = "Apple banana APPLE apple"
    let ciMatches = FindEngine.matches(in: text,
                                       options: .init(query: "apple", regex: false, caseSensitive: false))
    expectEqual(ciMatches.count, 3, "不区分大小写 3 处匹配")
    let ns = text as NSString
    expectEqual(ns.substring(with: ciMatches[0]), "Apple", "第 1 处内容")
    expectEqual(ns.substring(with: ciMatches[2]), "apple", "第 3 处内容")

    let csMatches = FindEngine.matches(in: text,
                                       options: .init(query: "APPLE", regex: false, caseSensitive: true))
    expectEqual(csMatches.count, 1, "区分大小写 1 处匹配")

    let phoneText = "电话 13812345678,备用 87654321"
    let reMatches = FindEngine.matches(in: phoneText,
                                       options: .init(query: "\\d{6,}", regex: true, caseSensitive: false))
    expectEqual(reMatches.count, 2, "正则 2 处匹配")
    let pns = phoneText as NSString
    expectEqual(pns.substring(with: reMatches[0]), "13812345678", "正则第 1 处内容")

    let dateText = "2026-01-01 和 2026-12-31"
    let (result, count) = FindEngine.replaceAll(
        in: dateText,
        options: .init(query: "(\\d{4})-(\\d{2})-(\\d{2})", regex: true, caseSensitive: false),
        template: "$3/$2/$1")
    expectEqual(count, 2, "正则替换 2 处")
    expectEqual(result, "01/01/2026 和 31/12/2026", "$n 反向引用正确")

    let (plainResult, plainCount) = FindEngine.replaceAll(
        in: "猫追狗,狗跑,猫笑",
        options: .init(query: "猫", regex: false, caseSensitive: false),
        template: "鼠")
    expectEqual(plainCount, 2, "普通替换 2 处")
    expectEqual(plainResult, "鼠追狗,狗跑,鼠笑", "普通替换内容")

    expectTrue(FindEngine.matches(in: "abc", options: .init(query: "", regex: false, caseSensitive: false)).isEmpty,
               "空查询无匹配")
    expectTrue(FindEngine.matches(in: "abc", options: .init(query: "([", regex: true, caseSensitive: false)).isEmpty,
               "非法正则安全返回空")

    let lineText = "line one\nline two\nthree"
    let anchored = FindEngine.matches(in: lineText,
                                      options: .init(query: "^line", regex: true, caseSensitive: false))
    expectEqual(anchored.count, 2, "行首锚点 2 处")
    expectEqual(anchored[1].location, 9, "行首锚点第 2 处位置")
}

// MARK: - 语法高亮

func testSyntaxHighlighter() {
    suite("语法高亮")

    let swiftCode = "let x = 1 // note"
    let tokens = SyntaxHighlighter.tokens(for: swiftCode, language: .swift)
    let sns = swiftCode as NSString
    expectTrue(tokens.contains { sns.substring(with: $0.0) == "let" }, "关键字 let 命中")
    expectTrue(tokens.contains { sns.substring(with: $0.0) == "// note" }, "行注释命中")

    let tricky = #"let s = "class in string""#
    let trickyTokens = SyntaxHighlighter.tokens(for: tricky, language: .swift)
    let tns = tricky as NSString
    let stringRange = tns.range(of: #""class in string""#)
    expectTrue(trickyTokens.contains { $0.0 == stringRange }, "字符串整体命中 string token")
    let inner = NSRange(location: stringRange.location + 1, length: 5) // "class"
    expectFalse(trickyTokens.contains { $0.0.location == inner.location },
                "字符串内的 class 不作为关键字")

    let blockComment = "a /* comment\nspan */ b"
    let bcTokens = SyntaxHighlighter.tokens(for: blockComment, language: .ccpp)
    let bns = blockComment as NSString
    expectTrue(bcTokens.contains { bns.substring(with: $0.0).contains("span") }, "块注释跨行命中")

    expectTrue(SyntaxHighlighter.tokens(for: "anything", language: .plain).isEmpty, "纯文本无 token")

    expectEqual(ProgLanguage.detect(fromFileName: "note.md"), .markdown, "扩展名 md")
    expectEqual(ProgLanguage.detect(fromFileName: "config.json"), .json, "扩展名 json")
    expectEqual(ProgLanguage.detect(fromFileName: "main.py"), .python, "扩展名 py")
    expectEqual(ProgLanguage.detect(fromFileName: "App.swift"), .swift, "扩展名 swift")
    expectEqual(ProgLanguage.detect(fromFileName: "run.sh"), .shell, "扩展名 sh")
    expectEqual(ProgLanguage.detect(fromFileName: "unknown.xyz"), .plain, "未知扩展名纯文本")
}

// MARK: - 会话模型

func testSessionStore() throws {
    suite("会话模型")

    var state = SessionState()
    state.tabs = [
        SessionTabState(filePath: "/tmp/a.txt", draftID: "11111111-2222-3333-4444-555555555555",
                        displayName: "a.txt", encoding: "utf8", eol: "LF", language: "plain",
                        cursorLocation: 12, scrollFraction: 0.5),
        SessionTabState(filePath: nil, draftID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                        displayName: "未命名-1", encoding: "gb18030", eol: "CRLF", language: "markdown",
                        cursorLocation: 0, scrollFraction: 0),
    ]
    state.activeIndex = 1
    state.windowFrame = NSStringFromRect(NSRect(x: 10, y: 20, width: 800, height: 600))

    let encoder = JSONEncoder()
    let data = try encoder.encode(state)
    let decoded = try JSONDecoder().decode(SessionState.self, from: data)

    expectEqual(decoded.tabs.count, 2, "标签数量往返")
    expectEqual(decoded.tabs[0].filePath, "/tmp/a.txt", "文件路径往返")
    expectEqual(decoded.tabs[0].cursorLocation, 12, "光标位置往返")
    expectEqual(decoded.tabs[1].displayName, "未命名-1", "草稿名往返")
    expectEqual(decoded.tabs[1].encoding, "gb18030", "编码字段往返")
    expectEqual(decoded.activeIndex, 1, "激活索引往返")
    expectEqual(decoded.windowFrame, state.windowFrame, "窗口框往返")

    let tab = EditorTab.newDraft(name: "未命名-7")
    tab.encoding = .utf8BOM
    tab.eol = .crlf
    tab.language = .json
    let tabState = SessionStore.tabState(from: tab)
    expectNil(tabState.filePath, "草稿无文件路径")
    expectEqual(tabState.displayName, "未命名-7", "草稿名转换")
    expectEqual(tabState.encoding, "utf8BOM", "编码属性转换")
    expectEqual(tabState.eol, "CRLF", "行尾属性转换")
    expectEqual(tabState.language, "json", "语言属性转换")

    // rawValue 稳定性(写进 session.json 的兼容承诺)
    expectEqual(TextEncoding(rawValue: "utf8BOM"), .utf8BOM, "TextEncoding rawValue 稳定")
    expectEqual(TextEncoding(rawValue: "gb18030"), .gb18030, "gb18030 rawValue 稳定")
    expectEqual(LineEnding(rawValue: "CRLF"), .crlf, "LineEnding rawValue 稳定")
    expectEqual(ProgLanguage(rawValue: "ccpp"), .ccpp, "ProgLanguage rawValue 稳定")

    // 拉丁编码无法表示中文 → 降级 UTF-8(需先有内容,空内容不会触发降级)
    let fallbackTab = EditorTab.newDraft(name: "t")
    fallbackTab.encoding = .latin1
    fallbackTab.associate(fileURL: URL(fileURLWithPath: "/tmp/test-fallback.txt"))
    fallbackTab.content = "中文内容"
    let payload = fallbackTab.serializedContent()
    expectEqual(fallbackTab.encoding, .utf8, "编码降级为 UTF-8")
    expectTrue(String(data: payload.primary, encoding: .utf8) != nil, "降级后内容可解码")

    // 另存为默认名:无扩展名补 .txt;已有扩展名保持
    expectEqual(EditorTab.suggestedSaveName("未命名-1"), "未命名-1.txt", "无扩展名默认补 .txt")
    expectEqual(EditorTab.suggestedSaveName("note.md"), "note.md", "已有扩展名保持不变")
    expectEqual(EditorTab.suggestedSaveName("config.json"), "config.json", "json 扩展名保持")
}

// MARK: - 标签栏几何(多行折行回归:标题/✕/➕ 必须落在自己所在行)

func testTabBarLayout() {
    suite("标签栏多行布局")

    // 窗口 1000 宽:每行容量 = 1000/165 = 6;8 个标签 → 顺序填充 6+2
    let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 1000, height: 90))
    let items = (0..<8).map { i in
        TabDisplayItem(id: UUID(), title: "未命名-\(i)", dirty: i % 2 == 0, active: i == 1)
    }
    bar.refresh(items: items)
    bar.performLayout()
    let rects = bar.layoutRects

    expectEqual(rects.count, 8, "8 个标签全部有布局矩形")
    let expectedWidth = (CGFloat(1000) - 32) / 6
    expectEqual(rects[0], NSRect(x: 0, y: 0, width: expectedWidth, height: 30), "第 1 个在第一行行首")
    expectEqual(rects[5], NSRect(x: 5 * expectedWidth, y: 0, width: expectedWidth, height: 30), "前 6 个保持第一行(新增不重排)")
    expectEqual(rects[6].minY, 30, "第 7 个标签追加到第二行")
    expectEqual(rects[6].minX, 0, "第二行从行首开始")
    expectEqual(bar.contentHeight, 60, "两行标签栏高度 = 60")

    // 核心回归:✕ 关闭按钮判定区必须落在自己所在标签内部(多行错位 bug)
    for (i, rect) in rects.enumerated() {
        let close = bar.closeButtonRect(at: i)
        expectTrue(rect.contains(close), "✕ 判定区在标签 \(i) 所在行内")
        expectTrue(abs(close.midY - rect.midY) < 1, "✕ 判定区与标签 \(i) 垂直居中对齐")
    }

    // ➕ 按钮跟随最后一个标签所在行,且在栏内
    let plus = bar.plusButtonRect
    expectTrue(plus.minY >= 30 && plus.minY < 60, "➕ 在第二行")
    expectTrue(plus.maxX <= 1000 && plus.minX >= 0, "➕ 横向在栏内")

    // 单行不折行:6 个标签在 1000 宽下应为 1 行,且 ➕ 与标签同一行(不孤悬一行)
    let bar2 = TabBarView(frame: NSRect(x: 0, y: 0, width: 1000, height: 30))
    bar2.refresh(items: (0..<6).map { TabDisplayItem(id: UUID(), title: "t\($0)", dirty: false, active: false) })
    bar2.performLayout()
    expectEqual(bar2.contentHeight, 30, "6 个标签保持单行")
    expectEqual(bar2.layoutRects.count, 6, "单行 6 个矩形")
    expectEqual(bar2.plusButtonRect.minY, 0, "➕ 与标签同一行(不单独占一行)")
    expectTrue(bar2.plusButtonRect.maxX <= 1000, "➕ 在栏内")

    // 占满整行的场景:8 个标签两行 4+4,➕ 在第二行行尾且在栏内
    expectTrue(bar.plusButtonRect.maxX <= 1000, "两行时 ➕ 在栏内")
}

func expectNil<T>(_ value: T?, _ message: String, file: String = #file, line: Int = #line) {
    report(value == nil, message, file: file, line: line)
}

// MARK: - 历史文档存储

func testHistoryStore() {
    suite("历史文档存储")

    let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nphistory-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmpRoot) }

    let store = HistoryStore(baseURL: tmpRoot)
    expectEqual(store.entries.count, 0, "初始为空")

    func draftTab(_ name: String, _ content: String) -> EditorTab {
        let t = EditorTab.newDraft(name: name)
        t.restoreContent(content)
        return t
    }

    // 记录 3 条草稿
    store.record(tab: draftTab("甲", "内容甲"), content: "内容甲")
    store.record(tab: draftTab("乙", "内容乙"), content: "内容乙")
    store.record(tab: draftTab("丙", "内容丙"), content: "内容丙")
    expectEqual(store.entries.count, 3, "3 条记录")
    expectEqual(store.entries[0].title, "丙", "最新在最前")
    expectEqual(store.content(of: store.entries[0]) ?? "", "内容丙", "快照内容正确")

    // 命名文件按路径去重:同一路径关两次只留最新一条
    let fileURL = URL(fileURLWithPath: "/tmp/hist-dup.txt")
    let fileTab1 = EditorTab.newDraft(name: "hist-dup.txt")
    fileTab1.associate(fileURL: fileURL)
    store.record(tab: fileTab1, content: "第一次关闭")
    let fileTab2 = EditorTab.newDraft(name: "hist-dup.txt")
    fileTab2.associate(fileURL: fileURL)
    store.record(tab: fileTab2, content: "第二次关闭")
    expectEqual(store.entries.count, 4, "同路径去重后仍 4 条(3 草稿 + 1 文件)")
    expectEqual(store.entries[0].filePath ?? "", "/tmp/hist-dup.txt", "去重后最新条目在前")
    expectEqual(store.content(of: store.entries[0]) ?? "", "第二次关闭", "去重后内容为新版")

    // 取出(remove)语义:显式删除单条时移除且快照删除
    let picked = store.entries[1]
    store.remove(id: picked.id)
    expectEqual(store.entries.count, 3, "移除后 3 条")
    expectTrue(store.entries.first(where: { $0.id == picked.id }) == nil, "条目已删除")

    // 档案保留语义:打开历史条目(读内容)不影响条目本身,可反复恢复
    let archive = store.entries[0]
    expectEqual(store.content(of: archive) ?? "", "第二次关闭", "第一次读取内容正确")
    expectEqual(store.content(of: archive) ?? "", "第二次关闭", "第二次读取内容一致(可反复恢复)")
    expectTrue(store.entries.contains(where: { $0.id == archive.id }), "读取后条目仍保留在历史中")

    // 上限 50:写入 60 条,应剩 50 且最旧的被淘汰
    for i in 0..<60 {
        store.record(tab: draftTab("批量-\(i)", "批量内容-\(i)"), content: "批量内容-\(i)")
    }
    expectEqual(store.entries.count, HistoryStore.maxEntries, "上限 50 条")
    expectEqual(store.entries[0].title, "批量-59", "最新在前")
    expectFalse(store.entries.contains { $0.title == "批量-0" }, "最旧条目被淘汰")

    // clear 清空
    store.clear()
    expectEqual(store.entries.count, 0, "清空后为空")

    // 持久化往返:重启(load)后顺序不变 —— 最后关闭的仍然在最上面
    let storeA = HistoryStore(baseURL: tmpRoot)
    storeA.record(tab: draftTab("早关的", "x"), content: "x")
    storeA.record(tab: draftTab("中关的", "y"), content: "y")
    storeA.record(tab: draftTab("晚关的", "z"), content: "z")
    let storeB = HistoryStore(baseURL: tmpRoot) // 模拟重启重新加载
    expectEqual(storeB.entries.count, 3, "重启后条目数不变")
    expectEqual(storeB.entries[0].title, "晚关的", "重启后最新关闭的仍在最上面")
    expectEqual(storeB.entries[2].title, "早关的", "重启后最早的在最后")

    // 默认可见条数常量约定
    expectEqual(HistoryStore.defaultVisibleEntries, 10, "默认显示 10 条")
    expectEqual(HistoryStore.maxEntries, 50, "上限 50 条")
}

// MARK: - 入口

_ = NSApplication.shared // 初始化 AppKit(部分用例触碰 NSTextView)

testEncoding()
testLineEnding()
testLineIndex()
testFindEngine()
testSyntaxHighlighter()
try! testSessionStore()
testTabBarLayout()
testHistoryStore()

print("\n========================")
print("通过 \(passCount) 项,失败 \(failCount) 项")
exit(failCount == 0 ? 0 : 1)
