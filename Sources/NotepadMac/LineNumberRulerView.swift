import AppKit
import NotepadCore

/// 行号标尺:只绘制可视区域,软换行的后续片段不重复显示行号;
/// 当前行号加粗高亮(Notepad++ 行为)。
final class LineNumberRulerView: NSRulerView {

    weak var textView: EditorTextView?

    /// 标尺从控制器读取最新行索引(懒重建),自身不持有文本。
    var lineIndexProvider: (() -> LineIndex?)?

    init(textView: EditorTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
    }

    required init(coder: NSCoder) {
        fatalError("不支持 IB 初始化")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let scrollView = textView.enclosingScrollView,
              let index = lineIndexProvider?() else { return }

        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        guard glyphRange.length > 0 || textView.string.isEmpty == false else { return }

        // 依据行数自适应标尺宽度
        let digits = max(3, String(index.lineCount).count)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let width = CGFloat(digits) * font.maximumAdvancement.width + 18
        if abs(ruleThickness - width) > 1 {
            ruleThickness = width
        }

        // 背景 + 分隔线(坐标系随滚动,fill 会被裁剪到可视区域)
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.width - 1, y: visibleRect.minY, width: 1, height: visibleRect.height).fill()

        // 光标所在行(高亮)
        let caretLocation = textView.selectedRange().location
        let caretLine = index.lineNumber(at: caretLocation)

        var lastDrawnLine = -1

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { [weak self] fragRect, usedRect, _, fragGlyphRange, _ in
            guard let self = self else { return }
            let charRange = layoutManager.characterRange(forGlyphRange: fragGlyphRange, actualGlyphRange: nil)
            let line = index.lineNumber(at: charRange.location)

            // 软换行:同一逻辑行只画一次行号
            if line == lastDrawnLine { return }
            lastDrawnLine = line

            // 文档坐标 → 标尺坐标(兼容滚动式/覆盖式两种标尺布局)
            let docY = textView.textContainerInset.height + fragRect.minY
            let rulerY = self.convert(NSPoint(x: 0, y: docY), from: textView).y

            let numberString = String(line)
            let isCaretLine = (line == caretLine)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isCaretLine
                    ? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
                    : font,
                .foregroundColor: isCaretLine
                    ? NSColor.controlAccentColor
                    : NSColor.tertiaryLabelColor,
            ]
            let size = (numberString as NSString).size(withAttributes: attrs)
            let x = self.bounds.width - size.width - 10
            (numberString as NSString).draw(
                at: NSPoint(x: x, y: rulerY + (usedRect.height - size.height) / 2 - 1),
                withAttributes: attrs)
        }
    }
}
