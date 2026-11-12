import AppKit

// MARK: - 闭包 target 辅助(代码构建 UI 时连接 action 用)

final class ClosureTarget: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

// MARK: - 标签栏

struct TabDisplayItem {
    let id: UUID
    let title: String
    let dirty: Bool
    let active: Bool
}

/// 自绘标签栏:点击切换、关闭按钮、拖拽排序、中键关闭、右键菜单、文件拖放。
final class TabBarView: NSView {

    enum CloseScope { case single, others, all }

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onReorder: ((Int, Int) -> Void)?
    var onNewTab: (() -> Void)?
    var onFilesDropped: (([URL]) -> Void)?
    var onContextAction: ((Int, CloseScope) -> Void)?
    var onReopenLastClosed: (() -> Void)?

    private(set) var items: [TabDisplayItem] = []
    private var tabRects: [NSRect] = []
    private var hoverIndex = -1
    private var hoverClose = false
    private var hoverPlus = false
    private var contextTargets: [ClosureTarget] = []

    static let height: CGFloat = 30
    private static let minWidth: CGFloat = 90
    private static let maxWidth: CGFloat = 240
    private static let plusWidth: CGFloat = 32
    /// 期望标签宽度:低于此宽度开始折行
    private static let desiredWidth: CGFloat = 165
    /// 折行上限(防御极端标签数量把编辑区挤没)
    private static let maxRows = 5

    /// 标签栏实际内容高度(多行时大于 height),高度变化时通过回调更新外部约束
    private(set) var contentHeight: CGFloat = TabBarView.height
    var onHeightChanged: ((CGFloat) -> Void)?
    private var reportedHeight: CGFloat = TabBarView.height
    private var rowCount = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("不支持 IB 初始化") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    func refresh(items newItems: [TabDisplayItem]) {
        items = newItems
        needsDisplay = true
    }

    // MARK: 布局计算

    private var plusRect: NSRect = .zero

    private func layoutTabs() {
        tabRects = []
        plusRect = .zero
        let count = items.count
        guard count > 0 else {
            contentHeight = TabBarView.height
            notifyHeightIfNeeded()
            return
        }
        let avail = bounds.width

        // 顺序填充(贪心):填满一行再换下一行,前面的行位置永远不动 ——
        // 新建标签只是把新标签追加到下一行,已有标签不重排、宽度不变。
        let capacity = max(1, Int(avail / Self.desiredWidth))   // 每行容量(按期望宽度估算)
        let naturalRows = Int(ceil(Double(count) / Double(capacity)))
        let rows = min(max(1, naturalRows), Self.maxRows)
        // 触达折行上限时压缩每行数量以放下全部标签
        let perRow = naturalRows > Self.maxRows
            ? Int(ceil(Double(count) / Double(Self.maxRows)))
            : capacity
        // 标签宽度给 ➕ 预留 plusWidth,保证 ➕ 与最后一个标签同行
        let w = min(Self.maxWidth, (avail - Self.plusWidth) / CGFloat(perRow))
        let h = TabBarView.height
        rowCount = rows

        for i in 0..<count {
            let row = i / perRow
            let col = i % perRow
            tabRects.append(NSRect(x: CGFloat(col) * w, y: CGFloat(row) * h, width: w, height: h))
        }

        // ➕ 跟在最后一个标签后面;本行放不下则另起一行(防御分支,顺序填充下恒走同行)
        let lastRow = (count - 1) / perRow
        let lastCol = (count - 1) % perRow
        let plusX = CGFloat(lastCol + 1) * w
        if plusX + Self.plusWidth <= avail + 0.5 {
            plusRect = NSRect(x: plusX, y: CGFloat(lastRow) * h, width: Self.plusWidth, height: h)
            contentHeight = CGFloat(lastRow + 1) * h
        } else {
            plusRect = NSRect(x: 0, y: CGFloat(lastRow + 1) * h, width: Self.plusWidth, height: h)
            contentHeight = CGFloat(lastRow + 2) * h
        }
        notifyHeightIfNeeded()
    }

    private func notifyHeightIfNeeded() {
        if abs(contentHeight - reportedHeight) > 0.5 {
            reportedHeight = contentHeight
            onHeightChanged?(contentHeight)
        }
    }

    private func tabIndex(at point: NSPoint) -> Int? {
        for (i, r) in tabRects.enumerated() where r.contains(point) { return i }
        return nil
    }

    private func closeRect(for index: Int) -> NSRect {
        let r = tabRects[index]
        let size: CGFloat = 16
        let margin: CGFloat = 8
        // 必须基于 r.minY(所在行偏移),否则多行时点击判定区域错位到第一行
        return NSRect(x: r.maxX - size - margin,
                      y: r.minY + (r.height - size) / 2,
                      width: size, height: size)
    }

    // MARK: 供单元测试使用(几何正确性回归)

    /// 触发布局计算(headless 可调用)
    func performLayout() { layoutTabs() }

    /// 全部标签的布局矩形
    var layoutRects: [NSRect] { tabRects }

    /// ➕ 按钮矩形
    var plusButtonRect: NSRect { plusRect }

    /// ✕ 关闭按钮的点击判定矩形(与绘制/命中测试同一来源)
    func closeButtonRect(at index: Int) -> NSRect {
        guard items.indices.contains(index) else { return .zero }
        return closeRect(for: index)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        layoutTabs()

        // 背景
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        for (i, rect) in tabRects.enumerated() {
            let item = items[i]

            if item.active {
                NSColor.controlBackgroundColor.setFill()
                rect.fill()
                // 顶部强调线
                NSColor.controlAccentColor.setFill()
                NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2).fill()
            } else if i == hoverIndex {
                NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
                rect.fill()
            }

            // 标签间分隔线(基于所在行的 minY,多行时各自行内绘制)
            if !item.active, i < tabRects.count - 1 {
                NSColor.separatorColor.setFill()
                NSRect(x: rect.maxX - 0.5, y: rect.minY + 6, width: 0.5, height: rect.height - 12).fill()
            }

            // 标题(中段截断)
            let titleFont = NSFont.systemFont(ofSize: 12, weight: item.active ? .medium : .regular)
            let titleColor: NSColor = item.active ? .labelColor : .secondaryLabelColor
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            var titleText = item.title
            var titleAttrs: [NSAttributedString.Key: Any] = [
                .font: titleFont, .foregroundColor: titleColor, .paragraphStyle: paragraph,
            ]
            let maxTextWidth = rect.width - 46
            var textSize = (titleText as NSString).size(withAttributes: titleAttrs)
            if textSize.width > maxTextWidth {
                // 手动截断以便计算省略号
                while titleText.count > 1 {
                    titleText = String(titleText.dropLast()) 
                    let candidate = titleText + "…"
                    textSize = (candidate as NSString).size(withAttributes: titleAttrs)
                    if textSize.width <= maxTextWidth {
                        titleText = candidate
                        break
                    }
                }
                titleText = titleText.count > 1 ? titleText : "…"
            }
            let dirtyDot = item.dirty ? "● " : ""
            let full = dirtyDot + titleText
            titleAttrs[.paragraphStyle] = paragraph
            let attr = NSMutableAttributedString(string: full, attributes: titleAttrs)
            if item.dirty {
                attr.addAttribute(.foregroundColor, value: NSColor.systemOrange,
                                  range: NSRange(location: 0, length: dirtyDot.count))
            }
            // 文字纵向居中于所在行(多行折行时必须加上行偏移 rect.minY)
            let textRect = NSRect(x: rect.minX + 12,
                                  y: rect.minY + (rect.height - textSize.height) / 2,
                                  width: maxTextWidth, height: textSize.height + 2)
            attr.draw(in: textRect)

            // 关闭按钮 ✕
            let cRect = closeRect(for: i)
            let closePoint = NSPoint(x: cRect.midX, y: cRect.midY)
            let showClose = (i == hoverIndex) || item.active
            if showClose {
                if i == hoverIndex && hoverClose {
                    NSColor.quaternaryLabelColor.setFill()
                    NSBezierPath(roundedRect: cRect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
                }
                let xAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: (i == hoverIndex && hoverClose)
                        ? NSColor.labelColor : NSColor.tertiaryLabelColor,
                ]
                let size = ("✕" as NSString).size(withAttributes: xAttrs)
                ("✕" as NSString).draw(
                    at: NSPoint(x: closePoint.x - size.width / 2, y: closePoint.y - size.height / 2 + 1),
                    withAttributes: xAttrs)
            }
        }

        // 新建标签按钮 ➕(跟在最后一个标签后面)
        if !plusRect.isEmpty {
            if hoverPlus {
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: plusRect.insetBy(dx: 3, dy: 4), xRadius: 5, yRadius: 5).fill()
            }
            let plusAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: hoverPlus ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
            let size = ("+" as NSString).size(withAttributes: plusAttrs)
            ("+" as NSString).draw(
                at: NSPoint(x: plusRect.midX - size.width / 2, y: plusRect.midY - size.height / 2 + 1),
                withAttributes: plusAttrs)
        }

        // 多行时的行间分隔线(除最后一行外,每行底部画一条)
        for r in 0..<max(0, rowCount - 1) {
            let y = CGFloat(r + 1) * TabBarView.height - 1
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
        }

        // 底部分隔线
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: 交互

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        layoutTabs()

        // 新建标签按钮
        if !plusRect.isEmpty, plusRect.contains(point) {
            onNewTab?()
            return
        }

        guard let index = tabIndex(at: point) else {
            // 双击空白处新建标签在 mouseUp 中判断点击次数
            if event.clickCount == 2 { onNewTab?() }
            return
        }

        if closeRect(for: index).contains(point) {
            onClose?(index)
            return
        }

        onSelect?(index)

        // 按住拖动 → 实时排序
        let startPoint = point
        var current = index
        var dragging = false
        while let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if ev.type == .leftMouseUp { break }
            let p = convert(ev.locationInWindow, from: nil)
            if !dragging, abs(p.x - startPoint.x) > 6 { dragging = true }
            if dragging, let target = tabIndex(at: p), target != current {
                onReorder?(current, target)
                current = target
            }
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        // 中键关闭
        let point = convert(event.locationInWindow, from: nil)
        layoutTabs()
        if let index = tabIndex(at: point) {
            onClose?(index)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        layoutTabs()
        let index = tabIndex(at: point) ?? -1
        let onClose = index >= 0 && closeRect(for: index).contains(point)
        let onPlus = !plusRect.isEmpty && plusRect.contains(point)
        if index != hoverIndex || onClose != hoverClose || onPlus != hoverPlus {
            hoverIndex = index
            hoverClose = onClose
            hoverPlus = onPlus
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverIndex != -1 || hoverPlus {
            hoverIndex = -1
            hoverClose = false
            hoverPlus = false
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    // MARK: 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        layoutTabs()
        guard let index = tabIndex(at: point) else { return nil }
        onSelect?(index)

        let menu = NSMenu()
        contextTargets.removeAll()

        func addItem(_ title: String, _ action: @escaping () -> Void) {
            let target = ClosureTarget(action)
            contextTargets.append(target)
            let item = NSMenuItem(title: title, action: #selector(ClosureTarget.fire), keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }

        addItem("重新打开上次关闭的文档") { [weak self] in
            if let self = self { self.onReopenLastClosed?() }
        }
        menu.addItem(.separator())
        addItem("关闭标签") { [weak self] in
            if let self = self { self.onContextAction?(index, .single) }
        }
        addItem("关闭其他标签") { [weak self] in
            if let self = self { self.onContextAction?(index, .others) }
        }
        addItem("关闭全部标签") { [weak self] in
            if let self = self { self.onContextAction?(index, .all) }
        }
        return menu
    }

    // MARK: 文件拖放

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = fileURLs(from: sender.draggingPasteboard) else { return false }
        onFilesDropped?(urls)
        return true
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self],
                                                   options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !objects.isEmpty else { return nil }
        return objects
    }
}
