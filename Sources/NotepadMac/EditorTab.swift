import AppKit
import NotepadCore

/// 单个编辑标签:持有自己的 TextView / 滚动容器 / 行号标尺,以及文件、编码、行尾、语言等元数据。
final class EditorTab {

    // MARK: 身份

    let id = UUID()

    /// 已命名文件的路径;草稿为 nil
    private(set) var fileURL: URL?

    /// 内容快照位置(草稿即正式存储;命名文件作崩溃恢复备份),始终为 UTF-8
    let draftURL: URL

    /// 标签显示名(草稿为"未命名-N",文件为文件名)
    private(set) var displayName: String

    // MARK: 文本属性

    var encoding: TextEncoding = .utf8
    var eol: LineEnding = .lf
    var language: ProgLanguage = .plain

    // MARK: 持久化状态

    /// 自上次成功写盘后内容是否变化
    var isDirty = false
    /// 用户在关闭确认中选择「不保存」后置位:作废仍在后台队列中的自动保存写入
    var discardPendingWrites = false
    /// 内容代数:任何内容修改都递增,用于让后台写盘任务判断结果是否仍然有效
    var contentGeneration = 0
    /// 上次写盘后磁盘文件的修改时间(用于检测外部修改)
    var lastWrittenMtime: Date?
    /// 自动写盘失败(如权限不足)后置位,避免反复弹窗
    var writeFailed = false

    // MARK: 行索引(懒重建)

    private(set) var lineIndex = LineIndex()
    private var indexNeedsRebuild = true

    // MARK: 视图

    let scrollView: NSScrollView
    let textView: EditorTextView
    let ruler: LineNumberRulerView

    /// 打开时的初始滚动位置(恢复会话用,消费后置 nil)
    var pendingScrollFraction: Double?
    /// 打开时的初始光标位置(恢复会话用)
    var pendingCursorLocation: Int?

    /// 关闭标签时的清理回调(删除草稿文件等)
    var onCloseCleanup: ((EditorTab) -> Void)?

    // MARK: - 创建

    /// 新建未命名草稿
    static func newDraft(name: String, language: ProgLanguage = .plain) -> EditorTab {
        EditorTab(name: name, fileURL: nil, language: language)
    }

    /// 另存为的默认文件名:无扩展名时补 .txt(保存的默认格式)
    static func suggestedSaveName(_ displayName: String) -> String {
        let ext = (displayName as NSString).pathExtension
        return ext.isEmpty ? displayName + ".txt" : displayName
    }

    /// 从磁盘文件打开。返回 nil 表示读取失败(由调用方提示)。
    static func open(url: URL) -> EditorTab? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }

        let detection = TextCodec.detect(data)
        let content = LineEndingTool.normalizeToLF(detection.string)
        let language = data.count > SyntaxHighlighter.highlightSizeLimit
            ? .plain
            : ProgLanguage.detect(fromFileName: url.lastPathComponent)

        let tab = EditorTab(name: url.lastPathComponent, fileURL: url, language: language)
        tab.encoding = detection.encoding
        tab.eol = LineEndingTool.detect(detection.string)
        tab.setString(content)
        tab.lastWrittenMtime = tab.currentFileMtime()
        // 打开即写崩溃快照(UTF-8),源文件丢失/崩溃时仍有兜底
        if let snapshot = content.data(using: .utf8) {
            try? snapshot.write(to: tab.draftURL, options: .atomic)
        }
        return tab
    }

    private init(name: String, fileURL: URL?, language: ProgLanguage) {
        displayName = name
        self.fileURL = fileURL
        self.language = language
        draftURL = Preferences.draftsDir.appendingPathComponent(id.uuidString + ".txt")

        scrollView = NSScrollView()
        textView = EditorTextView(scrollContainer: scrollView)
        ruler = LineNumberRulerView(textView: textView)

        // 行号标尺
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = Preferences.lineNumbersEnabled
        scrollView.rulersVisible = Preferences.lineNumbersEnabled
        ruler.lineIndexProvider = { [weak self] in
            self?.rebuildIndexIfNeeded()
            return self?.lineIndex
        }

        applyWrapMode(enabled: Preferences.wrapEnabled)
    }

    deinit {
        onCloseCleanup = nil
    }

    // MARK: - 内容访问

    var content: String {
        get { textView.string }
        set {
            setString(newValue)
            markDirty()
        }
    }

    private func setString(_ s: String) {
        textView.string = s
        indexNeedsRebuild = true
    }

    /// 会话恢复时写入初始内容,并立刻把内容固化到本标签的快照文件。
    /// 不固化的窗口期内若应用退出,session.json 指向的新快照还是旧内容,未保存修改会丢。
    func restoreContent(_ s: String) {
        setString(s)
        needsFullHighlight = true
        if let data = s.data(using: .utf8) {
            try? data.write(to: draftURL, options: .atomic)
        }
    }

    var lineCount: Int {
        rebuildIndexIfNeeded()
        return lineIndex.lineCount
    }

    func rebuildIndexIfNeeded() {
        guard indexNeedsRebuild else { return }
        lineIndex.rebuild(text: textView.string)
        indexNeedsRebuild = false
    }

    // MARK: - 状态维护

    /// 内容被用户编辑后调用
    func markDirty() {
        isDirty = true
        contentGeneration += 1
        indexNeedsRebuild = true
        // 新的编辑代表新的保存意图,撤销之前的「丢弃」标记
        discardPendingWrites = false
    }

    /// 写盘成功后由控制器调用
    func markClean() {
        isDirty = false
        lastWrittenMtime = currentFileMtime()
    }

    /// 生成待写盘数据:草稿/快照一律 UTF-8;命名文件按标签编码 + 行尾编码。
    /// 返回 (主数据, 快照数据, 是否发生编码降级)。
    func serializedContent() -> (primary: Data, snapshot: Data, degraded: Bool) {
        let text = textView.string
        let snapshot = text.data(using: .utf8) ?? Data()

        if fileURL == nil {
            return (snapshot, snapshot, false)
        }
        let outText = LineEndingTool.apply(text, eol)
        if let data = TextCodec.encode(outText, encoding: encoding) {
            return (data, snapshot, false)
        }
        // 当前编码无法表示(如 Latin-1 遇到中文):降级 UTF-8,保证不丢数据
        encoding = .utf8
        let fallback = outText.data(using: .utf8) ?? Data()
        return (fallback, snapshot, true)
    }

    // MARK: - 元数据变更

    /// 另存为 / 关联到新文件
    func associate(fileURL url: URL) {
        fileURL = url
        displayName = url.lastPathComponent
        let detected = ProgLanguage.detect(fromFileName: url.lastPathComponent)
        language = detected
    }

    /// 外部修改检测:磁盘 mtime 与上次写盘时记录的不一致则视为外部改动
    func hasExternalChange() -> Bool {
        guard fileURL != nil, let mtime = currentFileMtime() else { return false }
        guard let recorded = lastWrittenMtime else { return true }
        return abs(mtime.timeIntervalSince(recorded)) > 0.001
    }

    func currentFileMtime() -> Date? {
        guard let url = fileURL else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    /// 从磁盘重新读取(自动重载 / 菜单"重新加载")
    func reloadFromDisk() {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        let detection = TextCodec.detect(data)
        let content = LineEndingTool.normalizeToLF(detection.string)

        // 尽量保留光标位置
        let oldCaret = textView.selectedRange().location
        setString(content)
        encoding = detection.encoding
        eol = LineEndingTool.detect(detection.string)
        let newLen = (content as NSString).length
        let restored = NSRange(location: min(oldCaret, newLen), length: 0)
        textView.setSelectedRange(restored)
        lastWrittenMtime = currentFileMtime()
        isDirty = false
        discardPendingWrites = false
        contentGeneration += 1
        needsFullHighlight = true
    }

    // MARK: - 视图配置

    func applyWrapMode(enabled: Bool) {
        guard let container = textView.textContainer else { return }
        if enabled {
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            // 自动换行下文本永不横向溢出,水平滚动条没有存在意义
            // (系统滚动条设为"始终显示"时若保留会常驻窗口底部,像一条进度条)
            scrollView.hasHorizontalScroller = false
        } else {
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.height]
            scrollView.hasHorizontalScroller = true
        }
        textView.refreshContentSize()
        textView.needsLayout = true
    }

    func applyLineNumbers(enabled: Bool) {
        scrollView.hasVerticalRuler = enabled
        scrollView.rulersVisible = enabled
    }

    func applyFont(_ font: NSFont) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        needsFullHighlight = true
    }

    // MARK: - 滚动 / 光标(会话恢复)

    var scrollFraction: Double {
        get {
            let clip = scrollView.contentView
            let docHeight = scrollView.documentView?.bounds.height ?? 0
            let visibleHeight = clip.bounds.height
            guard docHeight > visibleHeight else { return 0 }
            return Double(clip.bounds.minY / (docHeight - visibleHeight))
        }
        set {
            guard let doc = scrollView.documentView else { return }
            let docHeight = doc.bounds.height
            let visibleHeight = scrollView.contentView.bounds.height
            guard docHeight > visibleHeight else { return }
            let y = CGFloat(newValue) * (docHeight - visibleHeight)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), docHeight - visibleHeight)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    var cursorLocation: Int {
        let sel = textView.selectedRanges.first as? NSRange
        return sel?.location ?? 0
    }

    /// 内容写入视图后调用(打开/恢复时):应用待恢复的光标与滚动
    func restorePendingViewState() {
        let length = (textView.string as NSString).length
        if let cursor = pendingCursorLocation {
            textView.setSelectedRange(NSRange(location: min(cursor, length), length: 0))
            pendingCursorLocation = nil
        }
        if pendingScrollFraction != nil {
            // 布局完成后滚动位置才有意义,稍作延迟
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let f = self.pendingScrollFraction else { return }
                self.scrollFraction = f
                self.pendingScrollFraction = nil
            }
        }
    }

    // MARK: - 语法高亮状态(由控制器驱动)

    var needsFullHighlight = true

    /// 快照写盘(异步安全调用方在后台线程)。
    func writeSnapshotAsync(_ data: Data) {
        let url = draftURL
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 草稿同步读取(会话恢复时用)
    func readDraftSync() -> String? {
        guard let data = try? Data(contentsOf: draftURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除快照/草稿文件(关闭标签时)
    func removeDraftFile() {
        try? FileManager.default.removeItem(at: draftURL)
    }
}
