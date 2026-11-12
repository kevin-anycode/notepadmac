import AppKit

/// 底部状态栏:行:列 / 选区 / 字符数 / 行数,以及可点击切换的编码、行尾、语言。
final class StatusBarView: NSView {

    var onEncodingMenu: ((NSView) -> Void)?
    var onEOLMenu: ((NSView) -> Void)?
    var onLanguageMenu: ((NSView) -> Void)?

    private let positionLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let encodingButton = NSButton(title: "UTF-8", target: nil, action: nil)
    private let eolButton = NSButton(title: "LF", target: nil, action: nil)
    private let languageButton = NSButton(title: "纯文本", target: nil, action: nil)
    private var targets: [ClosureTarget] = []

    static let height: CGFloat = 26

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        for label in [positionLabel, countLabel] {
            label.font = font
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        positionLabel.alignment = .left

        for button in [encodingButton, eolButton, languageButton] {
            button.isBordered = false
            button.font = font
            button.contentTintColor = .secondaryLabelColor
            button.imagePosition = .noImage
        }
        encodingButton.toolTip = "点击切换文件编码"
        eolButton.toolTip = "点击切换换行符类型"
        languageButton.toolTip = "点击切换语法高亮语言"

        let stack = NSStackView(views: [positionLabel, countLabel, encodingButton, eolButton, languageButton])
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        stack.setCustomSpacing(8, after: positionLabel)
        stack.setCustomSpacing(14, after: countLabel)

        positionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        for button in [encodingButton, eolButton, languageButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
        }

        connect(button: encodingButton) { [weak self] in
            if let self = self { self.onEncodingMenu?(self.encodingButton) }
        }
        connect(button: eolButton) { [weak self] in
            if let self = self { self.onEOLMenu?(self.eolButton) }
        }
        connect(button: languageButton) { [weak self] in
            if let self = self { self.onLanguageMenu?(self.languageButton) }
        }
    }

    required init?(coder: NSCoder) { fatalError("不支持 IB 初始化") }

    private func connect(button: NSButton, handler: @escaping () -> Void) {
        let target = ClosureTarget(handler)
        targets.append(target)
        button.target = target
        button.action = #selector(ClosureTarget.fire)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: 更新

    private var overrideMessage: String?

    /// 临时提示(如"已保存"),传入 nil 恢复常规内容
    func applyOverrideMessage(_ message: String?) {
        overrideMessage = message
        if let message = message {
            positionLabel.stringValue = message
        }
    }

    func updatePosition(line: Int, column: Int, selectedChars: Int) {
        if overrideMessage != nil { return }
        var text = "行 \(line), 列 \(column)"
        if selectedChars > 0 {
            text += " · 已选 \(selectedChars) 字符"
        }
        positionLabel.stringValue = text
    }

    func updateCounts(totalChars: Int, totalLines: Int) {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let chars = formatter.string(from: NSNumber(value: totalChars)) ?? "\(totalChars)"
        countLabel.stringValue = "\(chars) 字符 · \(totalLines) 行"
    }

    func updateMeta(encoding: String, eol: String, language: String) {
        setButtonTitle(encodingButton, text: encoding)
        setButtonTitle(eolButton, text: eol)
        setButtonTitle(languageButton, text: language)
    }

    private func setButtonTitle(_ button: NSButton, text: String) {
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
    }
}
