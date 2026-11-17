import AppKit
import NotepadCore

/// 查找/替换条:仿 TextEdit 查找条 + Notepad++ 功能(全部高亮、正则、大小写、全部替换)。
final class FindBarView: NSView {

    // 回调
    var onQueryChanged: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrev: (() -> Void)?
    var onReplaceOne: (() -> Void)?
    var onReplaceAll: (() -> Void)?
    var onCloseRequest: (() -> Void)?

    // 子视图
    private let titleLabel = NSTextField(labelWithString: L("Find"))
    private let queryField = NSTextField()
    private let caseButton = NSButton(title: "Aa", target: nil, action: nil)
    private let regexButton = NSButton(title: ".*", target: nil, action: nil)
    private let matchCountLabel = NSTextField(labelWithString: "")
    private let prevButton = NSButton(title: L("Previous"), target: nil, action: nil)
    private let nextButton = NSButton(title: L("Next"), target: nil, action: nil)
    private let expandButton = NSButton(title: L("Replace ▸"), target: nil, action: nil)
    private let closeButton = NSButton(title: "✕", target: nil, action: nil)

    private let replaceLabel = NSTextField(labelWithString: L("Replace with"))
    private let replaceField = NSTextField()
    private let replaceOneButton = NSButton(title: L("Replace"), target: nil, action: nil)
    private let replaceAllButton = NSButton(title: L("Replace All"), target: nil, action: nil)

    private var targets: [ClosureTarget] = []
    private(set) var replaceMode = false

    static let height: CGFloat = 40
    static let heightWithReplace: CGFloat = 72

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        setupField(queryField, placeholder: L("Find text (Enter for next)"))
        setupField(replaceField, placeholder: L("Replacement text"))
        for label in [titleLabel, replaceLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.setContentHuggingPriority(.required, for: .horizontal)
        }

        setupToggle(caseButton, tooltip: L("Match case"))
        setupToggle(regexButton, tooltip: L("Regular expression"))
        matchCountLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        matchCountLabel.textColor = .secondaryLabelColor
        matchCountLabel.setContentHuggingPriority(.required, for: .horizontal)

        setupSmallButton(prevButton, symbol: "chevron.up", tooltip: L("Previous match (Cmd+Shift+G)"))
        setupSmallButton(nextButton, symbol: "chevron.down", tooltip: L("Next match (Cmd+G)"))
        setupSmallButton(closeButton, symbol: "xmark", tooltip: L("Close (Esc)"))

        for button in [expandButton, replaceOneButton, replaceAllButton] {
            button.isBordered = true
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 12)
            button.controlSize = .small
        }
        expandButton.toolTip = L("Expand replace field (Cmd+Alt+F)")
        replaceAllButton.keyEquivalentModifierMask = []

        // 第一行
        let row1 = NSStackView(views: [titleLabel, queryField, caseButton, regexButton,
                                       matchCountLabel, prevButton, nextButton, expandButton, closeButton])
        row1.orientation = .horizontal
        row1.spacing = 6
        row1.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row1)

        // 第二行
        let row2 = NSStackView(views: [replaceLabel, replaceField, replaceOneButton, replaceAllButton])
        row2.orientation = .horizontal
        row2.spacing = 6
        row2.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row2)

        NSLayoutConstraint.activate([
            row1.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row1.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row1.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            queryField.widthAnchor.constraint(equalToConstant: 240),
            replaceField.widthAnchor.constraint(equalToConstant: 240),

            row2.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row2.topAnchor.constraint(equalTo: row1.bottomAnchor, constant: 4),
        ])

        caseButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        regexButton.widthAnchor.constraint(equalToConstant: 32).isActive = true

        wireActions()
        replaceRowVisible(false)
    }

    required init?(coder: NSCoder) { fatalError("不支持 IB 初始化") }

    // MARK: 配置

    private func setupField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12)
        field.focusRingType = .default
        field.delegate = self
    }

    private func setupToggle(_ button: NSButton, tooltip: String) {
        button.isBordered = true
        button.bezelStyle = .rounded
        button.setButtonType(.pushOnPushOff)
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.controlSize = .small
        button.toolTip = tooltip
    }

    private func setupSmallButton(_ button: NSButton, symbol: String, tooltip: String) {
        button.isBordered = true
        button.bezelStyle = .rounded
        button.controlSize = .small
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            button.image = image
            button.imagePosition = .imageOnly
        }
        button.toolTip = tooltip
    }

    private func wireActions() {
        func bind(_ control: NSControl, _ handler: @escaping () -> Void) {
            let target = ClosureTarget(handler)
            targets.append(target)
            control.target = target
            control.action = #selector(ClosureTarget.fire)
        }
        bind(nextButton) { [weak self] in self?.onNext?() }
        bind(prevButton) { [weak self] in self?.onPrev?() }
        bind(closeButton) { [weak self] in self?.onCloseRequest?() }
        bind(replaceOneButton) { [weak self] in self?.onReplaceOne?() }
        bind(replaceAllButton) { [weak self] in self?.onReplaceAll?() }
        bind(expandButton) { [weak self] in self?.toggleReplaceMode() }
        bind(caseButton) { [weak self] in self?.onQueryChanged?() }
        bind(regexButton) { [weak self] in self?.onQueryChanged?() }

        // Enter → 下一个
        bind(queryField) { [weak self] in self?.onNext?() }
    }

    private func replaceRowVisible(_ visible: Bool) {
        replaceLabel.isHidden = !visible
        replaceField.isHidden = !visible
        replaceOneButton.isHidden = !visible
        replaceAllButton.isHidden = !visible
        expandButton.title = visible ? L("Replace ▾") : L("Replace ▸")
    }

    // MARK: 状态

    var options: FindEngine.Options {
        FindEngine.Options(
            query: queryField.stringValue,
            regex: regexButton.state == .on,
            caseSensitive: caseButton.state == .on)
    }

    var replacementTemplate: String { replaceField.stringValue }

    var isVisible: Bool { alphaValue > 0.01 && !isHidden }

    func show(replaceMode mode: Bool) {
        isHidden = false
        alphaValue = 1
        setReplaceMode(mode)
        focusQuery()
    }

    func hide() {
        isHidden = true
        queryField.stringValue = ""
        replaceField.stringValue = ""
        matchCountLabel.stringValue = ""
    }

    func focusQuery() {
        window?.makeFirstResponder(queryField)
        queryField.selectText(nil)
    }

    func setReplaceMode(_ on: Bool) {
        guard replaceMode != on else { return }
        replaceMode = on
        replaceRowVisible(on)
        onSizeChanged?(on)
    }

    func toggleReplaceMode() {
        setReplaceMode(!replaceMode)
    }

    var onSizeChanged: ((Bool) -> Void)?

    func setMatchCount(_ text: String) {
        matchCountLabel.stringValue = text
    }

    func setQuery(_ text: String) {
        queryField.stringValue = text
    }

    func setReplacement(_ text: String) {
        replaceField.stringValue = text
    }

    /// 截图演示用:程序化切换正则开关
    func setRegexEnabled(_ on: Bool) {
        regexButton.state = on ? .on : .off
    }
}

extension FindBarView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === queryField {
            onQueryChanged?()
        }
    }
}
