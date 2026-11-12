import AppKit

/// 编辑器主视图:纯文本模式 NSTextView,禁用各种自动替换(保证所见即所得)。
final class EditorTextView: NSTextView {

    /// 文本发生变化(用户输入、粘贴、替换)
    var onTextChanged: (() -> Void)?
    /// 选区/光标移动(用于状态栏 行:列 更新)
    var onSelectionChanged: (() -> Void)?

    init(scrollContainer: NSScrollView) {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)

        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.addTextContainer(container)

        super.init(frame: NSRect.zero, textContainer: container)

        // 纯文本编辑器行为
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isHorizontallyResizable = false
        isVerticallyResizable = true
        usesFindBar = false

        // 关闭自动更正/智能引号 —— 文本编辑器必须所见即所得
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        isAutomaticDataDetectionEnabled = false

        // 外观
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textColor = .labelColor
        insertionPointColor = .controlAccentColor
        selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor
        ]
        textContainerInset = NSSize(width: 6, height: 8)
        typingAttributes = [.font: Preferences.editorFont, .foregroundColor: NSColor.labelColor]

        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        scrollContainer.hasVerticalScroller = true
        scrollContainer.hasHorizontalScroller = true
        scrollContainer.autohidesScrollers = true
        scrollContainer.documentView = self
        scrollContainer.verticalRulerView = nil
        scrollContainer.rulersVisible = false

        // documentView 宽度跟随滚动区(关闭换行时由 refreshContentSize 接管宽度)
        autoresizingMask = [.width]
        frame = NSRect(x: 0, y: 0,
                       width: max(scrollContainer.contentSize.width, 1),
                       height: max(scrollContainer.contentSize.height, 1))
    }

    required init?(coder: NSCoder) {
        fatalError("不支持 IB 初始化")
    }

    /// 文本变化后同步 documentView 高度(纵向增长),关闭换行时同步宽度。
    /// 自动换行模式下还把 documentView 宽度精确对齐可视宽度 —— 否则任何 1px 的
    /// 超差都会让水平滚动条出现(系统滚动条设为"始终显示"时会常驻,像一条进度条)。
    func refreshContentSize() {
        guard let layoutManager = layoutManager, let container = textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let usedRect = layoutManager.usedRect(for: container)
        if isVerticallyResizable {
            let minHeight = enclosingScrollView?.contentSize.height ?? 0
            let target = usedRect.height + textContainerInset.height * 2
            if abs(frame.height - max(target, minHeight)) > 1 {
                frame.size.height = max(target, minHeight)
            }
        }
        if isHorizontallyResizable {
            let minWidth = enclosingScrollView?.contentSize.width ?? 0
            frame.size.width = max(usedRect.width + textContainerInset.width * 2, minWidth)
        } else if let scrollView = enclosingScrollView {
            let targetWidth = scrollView.contentSize.width
            if abs(frame.width - targetWidth) > 0.5 {
                frame.size.width = targetWidth
            }
        }
    }

    override func didChangeText() {
        super.didChangeText()
        refreshContentSize()
    }
}
