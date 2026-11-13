import AppKit
import NotepadCore

/// 主窗口控制器:单窗口多标签的核心编排者。
/// 职责:标签生命周期、自动保存管线、会话恢复、查找替换、语法高亮调度、编码/行尾转换。
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSTextViewDelegate {

    // MARK: - 模型

    private(set) var tabs: [EditorTab] = []
    private(set) var activeIndex = 0
    let sessionStore = SessionStore()
    let historyStore = HistoryStore()
    let autoSave = AutoSaveController()
    private let writeQueue = DispatchQueue(label: "com.notepadmac.write", qos: .utility)

    // MARK: - 视图

    private let tabBar = TabBarView()
    private let statusBar = StatusBarView()
    private let findBar = FindBarView()
    private let editorContainer = FileDropView()
    private var findHeightConstraint: NSLayoutConstraint!
    private var statusHeightConstraint: NSLayoutConstraint!
    private var tabHeightConstraint: NSLayoutConstraint!

    // MARK: - 内部状态

    private var draftCounter = 1
    private var hasOpenedAnyContent = false
    private var isHighlighting = false
    private var highlightWork: DispatchWorkItem?
    private var findRefreshWork: DispatchWorkItem?
    private var findMatches: [NSRange] = []
    private var findCurrent = -1
    private var keyMonitor: Any?
    private var metaMenuTargets: [ClosureTarget] = []

    var activeTab: EditorTab? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }

    // MARK: - 初始化

    init() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 680)
        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "NotepadMac"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.acceptsMouseMovedEvents = true

        buildViews()
        autoSave.onFlushNeeded = { [weak self] in self?.flushAll() }
        autoSave.start()
        restoreSessionOrNew()
        setupNotifications()
        setupKeyMonitor()
        centerWindowOnScreenIfNeeded()
    }

    required init?(coder: NSCoder) { fatalError("不支持 IB 初始化") }

    private func centerWindowOnScreenIfNeeded() {
        guard let window = window else { return }
        // 会话里没有记录过窗口位置时,放到屏幕中央
        let hasFrame = lastSessionWindowFrame != nil
        if !hasFrame {
            window.center()
        }
    }

    private var lastSessionWindowFrame: NSRect?

    // MARK: - 视图搭建

    private func buildViews() {
        guard let content = window?.contentView else { return }

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        for v in [tabBar, findBar, editorContainer, statusBar] {
            content.addSubview(v)
        }

        findHeightConstraint = findBar.heightAnchor.constraint(equalToConstant: 0)
        statusHeightConstraint = statusBar.heightAnchor.constraint(equalToConstant: Preferences.statusBarEnabled ? StatusBarView.height : 0)
        tabHeightConstraint = tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height)
        findBar.isHidden = true

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: content.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabHeightConstraint,

            findBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            findBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            editorContainer.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            editorContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editorContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            editorContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusHeightConstraint,
            findHeightConstraint,
        ])

        // 标签栏回调
        tabBar.onSelect = { [weak self] index in self?.selectTab(at: index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onReorder = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        tabBar.onNewTab = { [weak self] in self?.newDraftTab() }
        tabBar.onFilesDropped = { [weak self] urls in self?.openFiles(urls: urls) }
        tabBar.onContextAction = { [weak self] index, scope in
            self?.handleTabContextAction(index: index, scope: scope)
        }
        tabBar.onReopenLastClosed = { [weak self] in self?.reopenLastClosedDoc() }
        // 标签折行时标签栏变高,压缩编辑区
        tabBar.onHeightChanged = { [weak self] newHeight in
            self?.tabHeightConstraint.constant = newHeight
        }

        // 查找条回调
        findBar.onQueryChanged = { [weak self] in self?.updateFindMatches() }
        findBar.onNext = { [weak self] in self?.findNext() }
        findBar.onPrev = { [weak self] in self?.findPrevious() }
        findBar.onReplaceOne = { [weak self] in self?.replaceCurrentMatch() }
        findBar.onReplaceAll = { [weak self] in self?.replaceAllMatches() }
        findBar.onCloseRequest = { [weak self] in self?.closeFindBar() }
        findBar.onSizeChanged = { [weak self] expanded in
            self?.findHeightConstraint.constant = expanded ? FindBarView.heightWithReplace : FindBarView.height
        }

        // 状态栏菜单回调
        statusBar.onEncodingMenu = { [weak self] anchor in self?.showEncodingMenu(anchor: anchor) }
        statusBar.onEOLMenu = { [weak self] anchor in self?.showEOLMenu(anchor: anchor) }
        statusBar.onLanguageMenu = { [weak self] anchor in self?.showLanguageMenu(anchor: anchor) }

        // 编辑区文件拖放
        editorContainer.onFilesDropped = { [weak self] urls in self?.openFiles(urls: urls) }
    }

    // MARK: - 会话恢复

    private func restoreSessionOrNew() {
        if let state = sessionStore.loadSession(), !state.tabs.isEmpty {
            let restored = state.tabs.compactMap { SessionStore.restoreTab(from: $0, store: sessionStore) }
            if !restored.isEmpty {
                tabs = restored
                activeIndex = min(state.activeIndex, tabs.count - 1)
                if !state.windowFrame.isEmpty {
                    let frame = NSRectFromString(state.windowFrame)
                    if frame.width > 200 && frame.height > 200 {
                        lastSessionWindowFrame = frame
                        window?.setFrame(frame, display: false)
                    }
                }
                hasOpenedAnyContent = true
                updateDraftCounterFromRestored()
            }
        }
        if tabs.isEmpty {
            addDraftTab(activate: true)
        }

        for tab in tabs { tab.textView.delegate = self }
        attachActiveTabView()
        refreshAllUI()
        persistSession()
    }

    private func updateDraftCounterFromRestored() {
        let pattern = try? NSRegularExpression(pattern: "^未命名-(\\d+)$")
        var maxN = 0
        for tab in tabs where tab.fileURL == nil {
            if let re = pattern, let m = re.firstMatch(in: tab.displayName, range: NSRange(tab.displayName.startIndex..., in: tab.displayName)) {
                let s = (tab.displayName as NSString).substring(with: m.range(at: 1))
                if let n = Int(s) { maxN = max(maxN, n) }
            }
        }
        draftCounter = maxN + 1
    }

    // MARK: - 标签管理

    /// 把键盘焦点交给指定标签的编辑区。
    /// 延迟到下一轮 runloop:确保布局完成、脱离鼠标事件跟踪后再设置焦点,
    /// 否则焦点设置会静默失败,表现为"看不到光标、打字没反应"。
    func focusEditor(_ tab: EditorTab) {
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let self = self, let tab = tab, tab === self.activeTab else { return }
            self.window?.makeFirstResponder(tab.textView)
        }
    }

    /// 应用启动 / 窗口就绪后调用:确保当前标签获得键盘焦点
    func focusActiveEditor() {
        if let tab = activeTab {
            focusEditor(tab)
        }
    }

    private func addDraftTab(activate: Bool) {
        let tab = EditorTab.newDraft(name: "未命名-\(draftCounter)")
        draftCounter += 1
        tabs.append(tab)
        tab.textView.delegate = self
        if activate {
            activeIndex = tabs.count - 1
            attachActiveTabView()
            refreshAllUI()
            focusEditor(tab)
        }
        persistSession()
    }

    @objc func newDraftTab() {
        addDraftTab(activate: true)
    }

    /// 打开文件(Finder 打开方式 / 拖拽 / Cmd+O)
    func openFiles(urls: [URL], activateWindow: Bool = true) {
        discardEmptyInitialDraftIfNeeded()
        var openedPaths: [String] = []
        for url in urls {
            let path = url.path
            if let idx = tabs.firstIndex(where: { $0.fileURL?.path == path }) {
                selectTab(at: idx)
                continue
            }
            if let tab = EditorTab.open(url: url) {
                tabs.append(tab)
                tab.textView.delegate = self
                Preferences.addRecentFile(path)
                openedPaths.append(path)
                selectTab(at: tabs.count - 1)
            } else {
                showAlert("无法打开文件", "\(url.lastPathComponent) 读取失败(文件不存在或没有读取权限)。")
            }
        }
        if !openedPaths.isEmpty {
            persistSession()
        }
        hasOpenedAnyContent = true
        if activateWindow {
            window?.makeKeyAndOrderFront(self)
            focusActiveEditor()
        }
    }

    private func discardEmptyInitialDraftIfNeeded() {
        guard !hasOpenedAnyContent else { return }
        guard tabs.count == 1, let first = tabs.first,
              first.fileURL == nil, first.textView.string.isEmpty else { return }
        first.removeDraftFile()
        tabs.removeAll()
        activeIndex = 0
        hasOpenedAnyContent = true
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index), index != activeIndex else { return }
        autoSave.flushNow() // 先落盘当前标签
        activeIndex = index
        attachActiveTabView()
        refreshAllUI()
        activateTabExtras()
        persistSession()
    }

    /// 切换到新标签后的一次性动作
    private func activateTabExtras() {
        guard let tab = activeTab else { return }
        tab.restorePendingViewState()
        if tab.needsFullHighlight {
            applyHighlight(tab)
        }
        if findBar.isVisible {
            updateFindMatches()
        }
        focusEditor(tab)
        checkExternalChanges(userDriven: false, specificTab: tab)
    }

    private func attachActiveTabView() {
        editorContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let tab = activeTab else { return }
        let sv = tab.scrollView
        sv.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.addSubview(sv)
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            sv.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
        ])
        // 布局完成后同步 documentView 尺寸(恢复内容高度)
        DispatchQueue.main.async { [weak tab] in
            tab?.textView.refreshContentSize()
        }
    }

    private func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        activeIndex = to
        refreshAllUI()
        persistSession()
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]

        // 有未写盘的修改时,先询问是否保存(自动保存通常已落盘,此提示仅在写盘间隙/写盘失败时出现)
        guard tab.isDirty else {
            performCloseTab(at: index)
            return
        }
        askSaveBeforeClose(tabsToClose: [tab]) { [weak self] confirmed in
            guard confirmed, let self = self else { return }
            guard let current = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.performCloseTab(at: current)
        }
    }

    /// 真正执行关闭(无确认)。用户在提示中选择「不保存」时已把 isDirty 置 false,草稿会被清理。
    private func performCloseTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]

        // 关闭即留底历史文档(未保存的修改也能找回)
        historyStore.record(tab: tab, content: tab.textView.string)

        // 关闭前做一次防御性备份(正常路径已在确认时显式保存过)
        if tab.isDirty {
            writeTab(tab, synchronous: true, mode: .backupOnly)
        }
        if !tab.isDirty {
            tab.removeDraftFile()
        }

        tabs.remove(at: index)
        if tabs.isEmpty {
            activeIndex = 0
            addDraftTab(activate: true)
        } else {
            if index < activeIndex {
                activeIndex -= 1
            } else if index == activeIndex {
                activeIndex = min(index, tabs.count - 1)
            }
            attachActiveTabView()
            refreshAllUI()
            activateTabExtras()
        }
        persistSession()
    }

    /// 关闭/退出前的保存确认。[保存] [不保存] [取消]
    /// - confirmed: true = 继续关闭;false = 用户取消
    private func askSaveBeforeClose(tabsToClose: [EditorTab], proceed: @escaping (Bool) -> Void) {
        let dirty = tabsToClose.filter { $0.isDirty }
        guard !dirty.isEmpty, let win = window else {
            proceed(true)
            return
        }

        let alert = NSAlert()
        if dirty.count == 1, let tab = dirty.first {
            if let url = tab.fileURL {
                alert.messageText = "是否将更改保存到“\(url.lastPathComponent)”?"
                alert.informativeText = "该文档仍有未写盘的修改(自动保存通常已完成,此提示只在极新的修改尚未落盘时出现)。\n选择“不保存”将丢弃这些修改。"
            } else {
                alert.messageText = "是否保存草稿“\(tab.displayName)”?"
                alert.informativeText = "选择“保存”可挑选存放位置;选择“不保存”将丢弃草稿内容。"
            }
        } else {
            alert.messageText = "有 \(dirty.count) 个文档存在未写盘的修改"
            alert.informativeText = "是否保存这些修改?"
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")

        alert.beginSheetModal(for: win) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.saveTabsForClose(dirty, index: 0, proceed: proceed)
            case .alertSecondButtonReturn:
                // 不保存:丢弃未写盘的修改(作废后台写入;草稿文件随关闭清理)
                for tab in dirty {
                    tab.isDirty = false
                    tab.discardPendingWrites = true
                }
                proceed(true)
            default:
                proceed(false)
            }
        }
    }

    /// 确认后逐个保存:命名文件同步写回原文件;未命名草稿弹出另存为(取消则中止关闭)
    private func saveTabsForClose(_ dirty: [EditorTab], index: Int, proceed: @escaping (Bool) -> Void) {
        if index >= dirty.count {
            proceed(true)
            return
        }
        let tab = dirty[index]
        if tab.fileURL != nil {
            writeTab(tab, synchronous: true, mode: .explicitSave)
            // 写盘仍失败(如权限问题)→ 中止关闭,交给已弹出的引导
            proceed(!tab.isDirty)
            return
        }
        runSaveAsPanel(for: tab) { [weak self] saved in
            guard saved else { proceed(false); return }
            self?.saveTabsForClose(dirty, index: index + 1, proceed: proceed)
        }
    }

    @objc func closeActiveTab() {
        if let index = tabs.firstIndex(where: { $0 === activeTab }) {
            closeTab(at: index)
        }
    }

    @objc func closeOtherTabs() {
        guard let active = activeTab else { return }
        let closing = tabs.filter { $0 !== active }
        askSaveBeforeClose(tabsToClose: closing) { [weak self] confirmed in
            guard confirmed, let self = self else { return }
            var remaining: [EditorTab] = []
            for tab in self.tabs {
                if tab === active {
                    remaining.append(tab)
                    continue
                }
                self.historyStore.record(tab: tab, content: tab.textView.string)
                if !tab.isDirty { tab.removeDraftFile() }
            }
            self.tabs = remaining
            self.activeIndex = 0
            self.attachActiveTabView()
            self.refreshAllUI()
            self.activateTabExtras()
            self.persistSession()
        }
    }

    @objc func closeAllTabs() {
        askSaveBeforeClose(tabsToClose: tabs) { [weak self] confirmed in
            guard confirmed, let self = self else { return }
            for tab in self.tabs {
                self.historyStore.record(tab: tab, content: tab.textView.string)
                if !tab.isDirty {
                    tab.removeDraftFile()
                }
            }
            self.tabs.removeAll()
            self.activeIndex = 0
            self.addDraftTab(activate: true)
        }
    }

    private func handleTabContextAction(index: Int, scope: TabBarView.CloseScope) {
        switch scope {
        case .single:
            closeTab(at: index)
        case .others:
            guard tabs.indices.contains(index) else { return }
            activeIndex = index
            attachActiveTabView()
            refreshAllUI()
            closeOtherTabs()
        case .all:
            closeAllTabs()
        }
    }

    @objc func selectNextTab() {
        guard tabs.count > 1 else { return }
        selectTab(at: (activeIndex + 1) % tabs.count)
    }

    @objc func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        selectTab(at: (activeIndex - 1 + tabs.count) % tabs.count)
    }

    // MARK: - 打开 / 保存

    @objc func openFilesPanel() {
        guard let win = window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "选择要编辑的文本文件"
        panel.beginSheetModal(for: win) { [weak self] response in
            guard response == .OK else { return }
            self?.openFiles(urls: Array(panel.urls))
        }
    }

    @objc func openRecentPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openFiles(urls: [URL(fileURLWithPath: path)])
    }

    @objc func clearRecentFiles() {
        Preferences.recentFiles = []
    }

    /// Cmd+S:显式保存。未命名草稿会弹出存放位置选择;命名文件写回原文件。
    @objc func saveNow() {
        guard let tab = activeTab else { return }
        if tab.fileURL == nil {
            runSaveAsPanel(for: tab, completion: nil)
            return
        }
        writeTab(tab, synchronous: true, mode: .explicitSave)
        persistSession()
        flashStatus(tab.isDirty ? "保存失败,请尝试另存为" : "已保存")
    }

    @objc func saveCurrentAs() {
        guard let tab = activeTab else { return }
        runSaveAsPanel(for: tab, completion: nil)
    }

    /// 另存为面板:成功后把标签关联到新文件并立即写盘。saved = 用户是否完成了保存。
    private func runSaveAsPanel(for tab: EditorTab, completion: ((Bool) -> Void)?) {
        guard let win = window else {
            completion?(false)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = EditorTab.suggestedSaveName(tab.displayName)
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: win) { [weak self] response in
            guard response == .OK, let url = panel.url else {
                completion?(false)
                return
            }
            tab.associate(fileURL: url)
            tab.writeFailed = false
            tab.markDirty()
            self?.writeTab(tab, synchronous: true, mode: .explicitSave)
            Preferences.addRecentFile(url.path)
            self?.refreshAllUI()
            self?.persistSession()
            completion?(true)
        }
    }

    @objc func reloadActiveTab() {
        guard let tab = activeTab, tab.fileURL != nil, let win = window else { return }
        let performReload = { [weak self] in
            guard let tab = self?.activeTab else { return }
            tab.reloadFromDisk()
            self?.applyHighlight(tab)
            self?.refreshAllUI()
        }
        if tab.isDirty {
            let alert = NSAlert()
            alert.messageText = "重新加载文件?"
            alert.informativeText = "该文件有未落盘的修改,重新加载将丢弃这些修改。"
            alert.addButton(withTitle: "重新加载")
            alert.addButton(withTitle: "取消")
            alert.alertStyle = .warning
            alert.beginSheetModal(for: win) { response in
                if response == .alertFirstButtonReturn { performReload() }
            }
        } else {
            performReload()
        }
    }

    // MARK: - 自动保存管线

    /// 写盘模式
    /// - backupOnly: 自动备份 —— 只写应用内快照(防崩溃/退出丢失),不动原文件,不清脏标记
    /// - explicitSave: 显式保存 —— 写回原文件(命名文件)+ 更新快照,清脏标记
    enum WriteMode {
        case backupOnly
        case explicitSave
    }

    /// 自动备份:由去抖/周期/失焦触发
    func flushAll() {
        persistSession()
        for tab in tabs where tab.isDirty {
            writeTab(tab, synchronous: false, mode: .backupOnly)
        }
    }

    /// 退出前的保存确认:有未保存修改时询问[保存并退出 / 不保存退出 / 取消]。
    /// 返回是否允许退出。
    func confirmTerminate() -> Bool {
        let dirty = tabs.filter { $0.isDirty }
        guard !dirty.isEmpty else {
            persistSession()
            return true
        }
        let alert = NSAlert()
        if dirty.count == 1, let tab = dirty.first {
            alert.messageText = "是否保存对“\(tab.displayName)”的更改?"
        } else {
            alert.messageText = "有 \(dirty.count) 个文档未保存"
        }
        alert.informativeText = "未保存的修改已自动备份,但只有选择“保存”才会写入原文件。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存并退出")
        alert.addButton(withTitle: "不保存退出")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for tab in dirty {
                writeTab(tab, synchronous: true, mode: .explicitSave)
            }
            persistSession()
            return true
        case .alertSecondButtonReturn:
            // 不保存退出:命名文件放弃修改(恢复读磁盘版);
            // 未命名草稿按 Notepad++ 语义直接移除(历史文档中留底,可找回)
            for tab in dirty {
                tab.isDirty = false
                tab.discardPendingWrites = true
                if tab.fileURL == nil {
                    historyStore.record(tab: tab, content: tab.textView.string)
                    tab.removeDraftFile()
                    if let idx = tabs.firstIndex(where: { $0 === tab }) {
                        tabs.remove(at: idx)
                    }
                }
            }
            if tabs.isEmpty {
                activeIndex = 0
                addDraftTab(activate: false)
            } else {
                activeIndex = min(activeIndex, tabs.count - 1)
            }
            persistSession()
            return true
        default:
            return false
        }
    }

    private func writeTab(_ tab: EditorTab, synchronous: Bool, mode: WriteMode) {
        let generation = tab.contentGeneration
        let payload = tab.serializedContent()
        // 自动备份永不触碰原文件
        let primaryURL = (mode == .explicitSave) ? tab.fileURL : nil
        let draftURL = tab.draftURL

        let finalize: (Error?) -> Void = { [weak self, weak tab] error in
            let updateUI: () -> Void = { [weak self, weak tab] in
                guard let tab = tab else { return }
                if let error = error {
                    if !tab.writeFailed {
                        tab.writeFailed = true
                        self?.alertWriteFailed(tab: tab, error: error)
                    }
                } else if generation == tab.contentGeneration, mode == .explicitSave {
                    tab.isDirty = false
                    tab.lastWrittenMtime = tab.currentFileMtime()
                }
                self?.refreshDirtyIndicators()
            }
            if synchronous {
                updateUI()
            } else {
                DispatchQueue.main.async(execute: updateUI)
            }
        }

        let performWrite: () -> Void = { [weak tab] in
            // 用户在关闭确认中选择了「不保存」:作废仍在队列中的这次写入
            guard let tab = tab, !tab.discardPendingWrites else { return }
            do {
                if let url = primaryURL {
                    try payload.primary.write(to: url, options: .atomic)
                }
                try payload.snapshot.write(to: draftURL, options: .atomic)
                finalize(nil)
            } catch {
                finalize(error)
            }
        }

        if synchronous {
            performWrite()
        } else {
            writeQueue.async(execute: performWrite)
        }
    }

    private func alertWriteFailed(tab: EditorTab, error: Error) {
        let alert = NSAlert()
        alert.messageText = "自动保存失败"
        alert.informativeText = "无法写入 \(tab.displayName):\(error.localizedDescription)\n\n内容已保留在内存中,请用「另存为」选择新的位置。"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "另存为…")
        alert.addButton(withTitle: "知道了")
        if let win = window {
            alert.beginSheetModal(for: win) { [weak self] response in
                if response == .alertFirstButtonReturn {
                    self?.saveCurrentAs()
                }
            }
        } else {
            alert.runModal()
        }
    }

    // MARK: - 历史文档

    /// 打开一条历史记录:命名文件还在 → 直接打开文件;否则从快照恢复为(未保存的)标签。
    /// 历史是档案:打开后条目保留,可反复恢复;由 50 条上限与「清空历史」管理体量。
    func openHistoryEntry(id: UUID) {
        guard let entry = historyStore.entries.first(where: { $0.id == id }) else { return }
        let snapshotContent = historyStore.content(of: entry)

        if let path = entry.filePath, FileManager.default.fileExists(atPath: path) {
            openFiles(urls: [URL(fileURLWithPath: path)])
            return
        }

        guard let content = snapshotContent else {
            flashStatus("该历史文档的内容已不存在")
            return
        }
        discardEmptyInitialDraftIfNeeded()
        let tab = EditorTab.newDraft(name: entry.title,
                                     language: ProgLanguage(rawValue: entry.language) ?? .plain)
        tab.encoding = TextEncoding(rawValue: entry.encoding) ?? .utf8
        tab.eol = LineEnding(rawValue: entry.eol) ?? .lf
        tab.restoreContent(content)
        tab.isDirty = true // 从历史恢复的内容视为未保存,提示链条继续生效
        tabs.append(tab)
        tab.textView.delegate = self
        activeIndex = tabs.count - 1
        attachActiveTabView()
        refreshAllUI()
        activateTabExtras()
        focusEditor(tab)
        persistSession()
    }

    @objc func openHistoryEntryFromMenu(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString) else { return }
        openHistoryEntry(id: id)
    }

    /// Cmd+Shift+T:重新打开最近关闭的文档
    @objc func reopenLastClosedDoc() {
        guard let first = historyStore.entries.first else {
            flashStatus("暂无历史文档")
            return
        }
        openHistoryEntry(id: first.id)
    }

    @objc func clearHistoryDocuments() {
        let alert = NSAlert()
        alert.messageText = "清空历史文档?"
        alert.informativeText = "全部 \(historyStore.entries.count) 条历史记录及其内容备份将被删除,无法恢复。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard let win = window else {
            historyStore.clear()
            return
        }
        alert.beginSheetModal(for: win) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self = self else { return }
            self.historyStore.clear()
            self.flashStatus("历史文档已清空")
        }
    }

    // MARK: - 会话持久化

    func persistSession() {
        var state = SessionState()
        state.tabs = tabs.map { SessionStore.tabState(from: $0) }
        state.activeIndex = activeIndex
        if let frame = window?.frame {
            state.windowFrame = NSStringFromRect(frame)
        }
        sessionStore.saveSession(state)
    }

    // MARK: - 语法高亮

    private func scheduleHighlight(_ tab: EditorTab) {
        tab.needsFullHighlight = true
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let tab = tab else { return }
            self?.applyHighlight(tab)
        }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func applyHighlight(_ tab: EditorTab) {
        guard tab === activeTab, let storage = tab.textView.textStorage else { return }
        isHighlighting = true
        defer { isHighlighting = false }

        let text = tab.textView.string
        storage.beginEditing()
        let full = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.foregroundColor, range: full)
        storage.removeAttribute(.obliqueness, range: full)
        let baseFont = Preferences.editorFont
        storage.addAttribute(.font, value: baseFont, range: full)

        if tab.language != .plain,
           (text as NSString).length <= SyntaxHighlighter.highlightSizeLimit {
            for (range, token) in SyntaxHighlighter.tokens(for: text, language: tab.language) {
                let attrs = SyntaxHighlighter.attributes(for: token, baseFont: baseFont)
                for (key, value) in attrs {
                    storage.addAttribute(key, value: value, range: range)
                }
            }
        }
        storage.endEditing()
        tab.needsFullHighlight = false
        tab.ruler.needsDisplay = true
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              let tab = tabs.first(where: { $0.textView === textView }) else { return }
        if isHighlighting { return }

        tab.markDirty()
        autoSave.scheduleDebouncedFlush()
        scheduleHighlight(tab)
        normalizeNewlinesIfNeeded(tab)
        refreshDirtyIndicators()
        refreshStatus()
        if findBar.isVisible {
            scheduleFindRefresh()
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        refreshStatus()
        activeTab?.ruler.needsDisplay = true
    }

    /// 粘贴进来的 CRLF / CR 归一化为 LF(NSTextView 内部约定)
    /// 注意:不能用 String.contains("\r"),"\r\n" 字素簇会让它误报 false,须用 UTF-16 检查
    private func normalizeNewlinesIfNeeded(_ tab: EditorTab) {
        guard tab.textView.string.utf16.contains(13) else { return }
        DispatchQueue.main.async { [weak self, weak tab] in
            guard let tab = tab, tab.textView.string.utf16.contains(13) else { return }
            let tv = tab.textView
            guard let storage = tv.textStorage else { return }
            let ns = tv.string as NSString
            let len = ns.length
            var ranges: [NSRange] = []
            var i = 0
            while i < len {
                let r = ns.rangeOfCharacter(from: CharacterSet(charactersIn: "\r"),
                                            options: [], range: NSRange(location: i, length: len - i))
                guard r.location != NSNotFound else { break }
                ranges.append(r)
                i = r.location + 1
            }
            guard !ranges.isEmpty else { return }
            tv.shouldChangeText(in: NSRange(location: 0, length: len), replacementString: nil)
            storage.beginEditing()
            for r in ranges.reversed() {
                storage.replaceCharacters(in: r, with: "\n")
            }
            storage.endEditing()
            tv.didChangeText()
            self?.refreshStatus()
        }
    }

    // MARK: - 状态刷新

    func refreshAllUI() {
        refreshTabBar()
        refreshStatus()
        refreshDirtyIndicators()
    }

    private func makeTabItems() -> [TabDisplayItem] {
        tabs.enumerated().map { index, tab in
            TabDisplayItem(id: tab.id,
                           title: tab.displayName,
                           dirty: tab.isDirty,
                           active: index == activeIndex)
        }
    }

    private func refreshTabBar() {
        tabBar.refresh(items: makeTabItems())
    }

    func refreshDirtyIndicators() {
        refreshTabBar()
        if let tab = activeTab {
            window?.title = tab.displayName
            window?.isDocumentEdited = tab.isDirty
        }
    }

    func refreshStatus() {
        guard let tab = activeTab else { return }
        tab.rebuildIndexIfNeeded()
        let text = tab.textView.string as NSString
        let sel = tab.textView.selectedRanges.first as? NSRange ?? NSRange(location: 0, length: 0)
        let line = tab.lineIndex.lineNumber(at: sel.location)
        let column = tab.lineIndex.column(at: sel.location)
        let selectedChars = sel.length

        statusBar.updatePosition(line: line, column: column, selectedChars: selectedChars)
        statusBar.updateCounts(totalChars: text.length, totalLines: tab.lineIndex.lineCount)
        statusBar.updateMeta(encoding: tab.encoding.displayName,
                             eol: tab.eol.rawValue,
                             language: tab.language.displayName)
    }

    /// 状态栏临时提示(如"已保存"),1.4 秒后自动恢复
    private var flashWork: DispatchWorkItem?
    private func flashStatus(_ message: String) {
        statusBar.applyOverrideMessage(message)
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.statusBar.applyOverrideMessage(nil)
            self?.refreshStatus()
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    // MARK: - 外部修改检测

    func checkExternalChanges(userDriven: Bool, specificTab: EditorTab? = nil) {
        let targets = specificTab.map { [$0] } ?? tabs
        for tab in targets where tab.fileURL != nil {
            guard tab.hasExternalChange() else { continue }
            if tab.isDirty {
                if userDriven || tab === activeTab {
                    askReloadChangedTab(tab)
                }
            } else {
                tab.reloadFromDisk()
                if tab === activeTab {
                    applyHighlight(tab)
                    refreshAllUI()
                }
            }
        }
    }

    private var reloadAlertShown = false
    private func askReloadChangedTab(_ tab: EditorTab) {
        guard !reloadAlertShown, let win = window else { return }
        reloadAlertShown = true
        let alert = NSAlert()
        alert.messageText = "文件已在其他程序中修改"
        alert.informativeText = "\(tab.displayName) 在磁盘上发生了变化,而本页也有修改。\n\n保留哪个版本?(另一个版本的副本已保存在应用快照中)"
        alert.addButton(withTitle: "保留我的内容")
        alert.addButton(withTitle: "加载磁盘版本")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: win) { [weak self] response in
            self?.reloadAlertShown = false
            guard response == .alertSecondButtonReturn else { return }
            tab.reloadFromDisk()
            self?.applyHighlight(tab)
            self?.refreshAllUI()
        }
    }

    // MARK: - 查找 / 替换

    @objc func showFind() {
        guard activeTab != nil else { return }
        prefillQueryFromSelection()
        findBar.show(replaceMode: false)
        findHeightConstraint.constant = FindBarView.height
        contentLayoutIfNeeded()
        updateFindMatches()
        findBar.focusQuery()
    }

    @objc func showReplace() {
        guard activeTab != nil else { return }
        prefillQueryFromSelection()
        findBar.show(replaceMode: true)
        findHeightConstraint.constant = FindBarView.heightWithReplace
        contentLayoutIfNeeded()
        updateFindMatches()
        findBar.focusQuery()
    }

    private func prefillQueryFromSelection() {
        guard let tab = activeTab else { return }
        let sel = (tab.textView.selectedRanges.first as? NSRange) ?? NSRange(location: 0, length: 0)
        if sel.length > 0, sel.length < 200 {
            let text = (tab.textView.string as NSString).substring(with: sel)
            if !text.contains("\n") {
                findBar.setQuery(text)
            }
        }
    }

    private func contentLayoutIfNeeded() {
        guard findBar.superview != nil else { return }
        findBar.superview?.layoutSubtreeIfNeeded()
    }

    @objc func closeFindBar() {
        findBar.hide()
        findHeightConstraint.constant = 0
        contentLayoutIfNeeded()
        clearFindHighlights()
        findMatches = []
        findCurrent = -1
        activeTab?.textView.window?.makeFirstResponder(activeTab?.textView)
    }

    @objc func findNext() {
        navigateMatch(direction: 1)
    }

    @objc func findPrevious() {
        navigateMatch(direction: -1)
    }

    private func navigateMatch(direction: Int) {
        guard let tab = activeTab, !findMatches.isEmpty else {
            updateFindMatches()
            return
        }
        findCurrent = (findCurrent + direction + findMatches.count) % findMatches.count
        let range = findMatches[findCurrent]
        centerOn(range: range, in: tab)
        findBar.setMatchCount("\(findCurrent + 1)/\(findMatches.count)")
    }

    private func updateFindMatches() {
        guard let tab = activeTab, findBar.isVisible else { return }
        clearFindHighlights()
        let text = tab.textView.string
        findMatches = FindEngine.matches(in: text, options: findBar.options)
        if let layoutManager = tab.textView.layoutManager {
            for range in findMatches {
                layoutManager.addTemporaryAttributes([.backgroundColor: SyntaxPalette.matchHighlight],
                                                    forCharacterRange: range)
            }
        }
        if findMatches.isEmpty {
            let queryEmpty = findBar.options.query.isEmpty
            findBar.setMatchCount(queryEmpty ? "" : "无匹配")
            findCurrent = -1
        } else {
            findCurrent = findCurrent < 0 ? -1 : min(findCurrent, findMatches.count - 1)
            findBar.setMatchCount(findCurrent < 0
                ? "\(findMatches.count) 处匹配"
                : "\(findCurrent + 1)/\(findMatches.count)")
        }
        tab.ruler.needsDisplay = true
    }

    private func scheduleFindRefresh() {
        findRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.updateFindMatches()
        }
        findRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func clearFindHighlights() {
        guard let tab = activeTab, let layoutManager = tab.textView.layoutManager,
              let storage = tab.textView.textStorage else { return }
        layoutManager.removeTemporaryAttribute(.backgroundColor,
                                               forCharacterRange: NSRange(location: 0, length: storage.length))
    }

    @objc func replaceCurrentMatch() {
        guard let tab = activeTab, findBar.isVisible else { return }
        let sel = tab.textView.selectedRange()
        if let idx = findMatches.firstIndex(where: { $0.location == sel.location && $0.length == sel.length }),
           sel.length > 0 {
            replaceRange(idx)
        } else {
            findNext()
        }
    }

    private func replaceRange(_ idx: Int) {
        guard let tab = activeTab, idx < findMatches.count else { return }
        let range = findMatches[idx]
        let template = findBar.replacementTemplate
        let replacement: String

        if findBar.options.regex {
            var opts: NSRegularExpression.Options = [.anchorsMatchLines]
            if !findBar.options.caseSensitive { opts.insert(.caseInsensitive) }
            let fullText = tab.textView.string
            guard let re = try? NSRegularExpression(pattern: findBar.options.query, options: opts),
                  let m = re.firstMatch(in: fullText, options: [], range: range) else { return }
            replacement = re.replacementString(for: m, in: fullText, offset: 0, template: template)
        } else {
            replacement = template
        }

        let tv = tab.textView
        tv.shouldChangeText(in: range, replacementString: replacement)
        tv.textStorage?.replaceCharacters(in: range, with: replacement)
        tv.didChangeText()

        // 刷新匹配并定位下一个
        let newMatches = FindEngine.matches(in: tv.string, options: findBar.options)
        let nextLocation = range.location + (replacement as NSString).length
        clearFindHighlights()
        findMatches = newMatches
        if let layoutManager = tv.layoutManager {
            for r in findMatches {
                layoutManager.addTemporaryAttributes([.backgroundColor: SyntaxPalette.matchHighlight],
                                                    forCharacterRange: r)
            }
        }
        findCurrent = findMatches.firstIndex(where: { $0.location >= nextLocation - 1 }) ?? -1
        if findCurrent >= 0, findMatches.indices.contains(findCurrent) {
            centerOn(range: findMatches[findCurrent], in: tab)
            findBar.setMatchCount("\(findCurrent + 1)/\(findMatches.count)")
        } else {
            findCurrent = -1
            findBar.setMatchCount(findMatches.isEmpty ? "已替换至末尾" : "")
        }
    }

    @objc func replaceAllMatches() {
        guard let tab = activeTab, findBar.isVisible else { return }
        let text = tab.textView.string
        let (newText, count) = FindEngine.replaceAll(in: text, options: findBar.options,
                                                    template: findBar.replacementTemplate)
        guard count > 0 else {
            findBar.setMatchCount("无匹配")
            return
        }
        let tv = tab.textView
        let full = NSRange(location: 0, length: (text as NSString).length)
        tv.shouldChangeText(in: full, replacementString: newText)
        tv.textStorage?.replaceCharacters(in: full, with: newText)
        tv.didChangeText()
        findBar.setMatchCount("已替换 \(count) 处")
        updateFindMatches()
    }

    /// 滚动并定位到指定范围(居中)
    private func centerOn(range: NSRange, in tab: EditorTab) {
        let tv = tab.textView
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
        guard let lm = tv.layoutManager, let container = tv.textContainer else { return }
        lm.ensureLayout(forCharacterRange: range)
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let fragRect = lm.boundingRect(forGlyphRange: glyphRange, in: container)
        let docRect = NSRect(x: fragRect.minX + tv.textContainerOrigin.x,
                             y: fragRect.minY + tv.textContainerOrigin.y,
                             width: fragRect.width,
                             height: fragRect.height)
        let clip = tab.scrollView.contentView
        var target = docRect
        target.origin.y -= max(0, (clip.bounds.height - docRect.height) / 2)
        target.origin.y = max(0, target.origin.y)
        clip.scroll(to: target.origin)
        tab.scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - 编辑辅助

    @objc func insertTimestamp() {
        guard let tv = activeTab?.textView else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let range = tv.selectedRange()
        tv.insertText(formatter.string(from: Date()), replacementRange: range)
    }

    @objc func uppercaseSelection() {
        activeTab?.textView.uppercaseWord(nil)
        refreshStatus()
    }

    @objc func lowercaseSelection() {
        activeTab?.textView.lowercaseWord(nil)
        refreshStatus()
    }

    @objc func gotoLine() {
        guard let tab = activeTab else { return }
        tab.rebuildIndexIfNeeded()
        let alert = NSAlert()
        alert.messageText = "跳转到行"
        alert.informativeText = "输入行号(1 - \(tab.lineIndex.lineCount)):"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "跳转")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let n = Int(trimmed), n >= 1 else { return }
        let line = min(n, tab.lineIndex.lineCount)
        let offset = tab.lineIndex.startOfLine(line)
        tab.textView.setSelectedRange(NSRange(location: offset, length: 0))
        centerOn(range: NSRange(location: offset, length: 0), in: tab)
        window?.makeFirstResponder(tab.textView)
    }

    // MARK: - 字体 / 缩放

    @objc func zoomIn() { adjustFontSize(delta: 1) }
    @objc func zoomOut() { adjustFontSize(delta: -1) }

    private func adjustFontSize(delta: Int) {
        let current = Preferences.fontSize
        let newSize = min(48, max(8, current + CGFloat(delta)))
        guard newSize != current else { return }
        Preferences.fontSize = newSize
        applyFontToAllTabs()
    }

    @objc func resetFontSize() {
        Preferences.fontSize = 13
        applyFontToAllTabs()
    }

    private func applyFontToAllTabs() {
        let font = Preferences.editorFont
        for tab in tabs {
            tab.applyFont(font)
            tab.textView.refreshContentSize()
        }
        if let tab = activeTab {
            applyHighlight(tab)
        }
        refreshStatus()
    }

    /// 字体面板(Cmd+T)回调:全局应用(NSFontManager.target 指向本控制器)
    @objc func changeFont(_ sender: Any?) {
        guard let fontManager = sender as? NSFontManager else { return }
        let converted = fontManager.convert(Preferences.editorFont)
        Preferences.fontName = converted.fontName
        Preferences.fontSize = converted.pointSize
        applyFontToAllTabs()
    }

    @objc func openFontPanel() {
        NSFontManager.shared.target = self
        NSFontPanel.shared.makeKeyAndOrderFront(self)
    }

    // MARK: - 视图开关

    @objc func toggleWrap() {
        Preferences.wrapEnabled.toggle()
        for tab in tabs {
            tab.applyWrapMode(enabled: Preferences.wrapEnabled)
            tab.textView.refreshContentSize()
        }
        persistSession()
    }

    @objc func toggleLineNumbers() {
        Preferences.lineNumbersEnabled.toggle()
        for tab in tabs {
            tab.applyLineNumbers(enabled: Preferences.lineNumbersEnabled)
        }
    }

    @objc func toggleStatusBar() {
        Preferences.statusBarEnabled.toggle()
        let on = Preferences.statusBarEnabled
        statusBar.isHidden = !on
        statusHeightConstraint.constant = on ? StatusBarView.height : 0
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    @objc func toggleOnTop() {
        Preferences.alwaysOnTop.toggle()
        window?.level = Preferences.alwaysOnTop ? .floating : .normal
    }

    // MARK: - 编码 / 行尾 / 语言

    @objc func convertEncodingTo(_ sender: NSMenuItem) {
        guard let tab = activeTab,
              let raw = sender.representedObject as? String,
              let encoding = TextEncoding(rawValue: raw) else { return }
        guard encoding != tab.encoding else { return }
        let outText = LineEndingTool.apply(tab.textView.string, tab.eol)
        guard TextCodec.canRepresent(outText, encoding: encoding) else {
            showAlert("无法转换编码",
                      "内容包含「\(encoding.displayName)」无法表示的字符。\n请先另存为 UTF-8,或移除这些字符后再试。")
            return
        }
        tab.encoding = encoding
        tab.markDirty()
        writeTab(tab, synchronous: true, mode: .explicitSave)
        refreshStatus()
        flashStatus("编码已转换为 \(encoding.displayName)")
    }

    @objc func convertEOLTo(_ sender: NSMenuItem) {
        guard let tab = activeTab,
              let raw = sender.representedObject as? String,
              let eol = LineEnding(rawValue: raw) else { return }
        guard eol != tab.eol else { return }
        tab.eol = eol
        tab.markDirty()
        writeTab(tab, synchronous: true, mode: .explicitSave)
        refreshStatus()
        flashStatus("换行符已转换为 \(eol.rawValue)")
    }

    @objc func setLanguageTo(_ sender: NSMenuItem) {
        guard let tab = activeTab,
              let raw = sender.representedObject as? String,
              let language = ProgLanguage(rawValue: raw) else { return }
        tab.language = language
        applyHighlight(tab)
        refreshStatus()
    }

    // MARK: - 状态栏弹出菜单

    private func popMetaMenu(anchor: NSView, items: [(title: String, raw: String)], handler: @escaping (String) -> Void) {
        metaMenuTargets.removeAll()
        let menu = NSMenu()
        for (title, raw) in items {
            let target = ClosureTarget { handler(raw) }
            metaMenuTargets.append(target)
            let item = NSMenuItem(title: title, action: #selector(ClosureTarget.fire), keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
        let point = NSPoint(x: anchor.bounds.minX, y: anchor.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: point, in: anchor)
    }

    private func showEncodingMenu(anchor: NSView) {
        popMetaMenu(anchor: anchor, items: TextEncoding.allCases.map { ($0.displayName, $0.rawValue) }) { [weak self] raw in
            self?.convertEncodingTo(MainWindowController.MenuItemStub(raw: raw))
        }
    }

    private func showEOLMenu(anchor: NSView) {
        popMetaMenu(anchor: anchor, items: LineEnding.allCases.map { ($0.displayName, $0.rawValue) }) { [weak self] raw in
            self?.convertEOLTo(MainWindowController.MenuItemStub(raw: raw))
        }
    }

    private func showLanguageMenu(anchor: NSView) {
        popMetaMenu(anchor: anchor, items: ProgLanguage.allCases.map { ($0.displayName, $0.rawValue) }) { [weak self] raw in
            self?.setLanguageTo(MainWindowController.MenuItemStub(raw: raw))
        }
    }

    /// 把 representedObject 包装成菜单项以复用菜单 action
    private final class MenuItemStub: NSMenuItem {
        init(raw: String) {
            super.init(title: "", action: nil, keyEquivalent: "")
            representedObject = raw
        }
        required init(coder: NSCoder) { fatalError("不支持 IB 初始化") }
    }

    // MARK: - 帮助

    @objc func showAbout() {
        let credits = NSMutableAttributedString(string:
            "macOS 原生文本编辑器\n对标 Notepad++ 的平替之作\n\n自动保存 · 会话恢复 · 多标签 · 语法高亮\n\n")
        credits.append(NSAttributedString(
            string: "开发者:L.K\nQQ:394808300",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "NotepadMac",
            .applicationVersion: "1.0",
            NSApplication.AboutPanelOptionKey.version: "1.0",
            .credits: credits,
        ])
    }

    @objc func openDataFolder() {
        NSWorkspace.shared.open(Preferences.appSupportDir)
    }

    // MARK: - 通知 / 键盘

    private func setupNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive),
                                               name: NSApplication.willResignActiveNotification, object: nil)
    }

    @objc private func appDidBecomeActive() {
        checkExternalChanges(userDriven: false)
    }

    @objc private func appWillResignActive() {
        flushAll()
    }

    private func setupKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Esc:关闭查找条
            if event.keyCode == 53, self.findBar.isVisible {
                self.closeFindBar()
                return nil
            }
            // Ctrl+Tab / Ctrl+Shift+Tab:切换标签
            if flags == [.control], event.charactersIgnoringModifiers == "\t" {
                self.selectNextTab()
                return nil
            }
            if flags == [.control, .shift], event.charactersIgnoringModifiers == "\t" {
                self.selectPreviousTab()
                return nil
            }
            // Cmd+1..9 直达标签
            if flags == [.command], let chars = event.charactersIgnoringModifiers,
               let num = Int(chars), num >= 1, num <= 9 {
                let index = num - 1
                if index < self.tabs.count {
                    self.selectTab(at: index)
                    return nil
                }
            }
            return event
        }
    }

    // MARK: - 演示截图模式(README 产品截图;由环境变量触发,正常运行不会进入)

    /// 构建展示性场景:多标签 + 语法高亮 + 查找条 + 状态栏脏标记
    func setupDemoContent() {
        window?.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: true)
        tabs.removeAll()
        historyStore.clear()

        let markdownTab = EditorTab.newDraft(name: "随笔·项目想法.md", language: .markdown)
        markdownTab.content = """
        # NotepadMac 项目随笔

        **11月12日** 定下了这个编辑器的三条底线:

        - 打开就写,永不丢失 —— 自动备份 + 会话恢复
        - 关键动作有确认 —— 关闭与退出都有保存提示
        - 历史可回溯 —— 误关的草稿一定能找回(上限 50 条)

        ## 明天要做
        1. 用真实样本再跑一遍 GB18030 检测
        2. 验证 1MB 大文件的滚动流畅度

        > 随手记,随手得。
        """

        let swiftTab = EditorTab.newDraft(name: "AutoSaveController.swift", language: .swift)
        swiftTab.content = """
        import Foundation

        /// 自动保存调度:去抖落盘 + 周期兜底
        final class AutoSaveController {

            static let debounceInterval: TimeInterval = 0.8
            static let sweepInterval: TimeInterval = 5.0

            var onFlushNeeded: (() -> Void)?
            private var sweepTimer: Timer?

            func start() {
                let timer = Timer(timeInterval: Self.sweepInterval, repeats: true) { [weak self] _ in
                    self?.onFlushNeeded?()
                }
                RunLoop.main.add(timer, forMode: .common)
                sweepTimer = timer
            }
        }
        """

        let jsonTab = EditorTab.newDraft(name: "settings.json", language: .json)
        jsonTab.content = """
        {
          "editor": {
            "font": "Menlo",
            "fontSize": 13,
            "wrap": true,
            "lineNumbers": true
          },
          "autosave": { "debounceMs": 800, "sweepSec": 5 },
          "history": { "maxEntries": 50, "defaultVisible": 10 }
        }
        """

        let noteTab = EditorTab.newDraft(name: "会议记录.txt", language: .plain)
        noteTab.content = """
        项目周会(11月12日)

        1. NotepadMac 打字延迟优化完成
        2. 历史文档功能上线,默认展示 10 条
        3. 下周:公证打包,发布 dmg
        """

        for tab in [markdownTab, swiftTab, jsonTab, noteTab] {
            tabs.append(tab)
            tab.textView.delegate = self
        }
        activeIndex = 0
        attachActiveTabView()
        for tab in tabs where tab.needsFullHighlight {
            applyHighlight(tab)
        }
        refreshAllUI()

        // 打开查找条并高亮命中,展示查找功能
        findBar.show(replaceMode: false)
        findHeightConstraint.constant = FindBarView.height
        findBar.setQuery("保存")
        updateFindMatches()
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// 切换到指定标签并离屏渲染窗口为 PNG。
    /// 注意:NSScrollView 的行号标尺不走离屏 draw 递归,需在 rep 上下文中手动补画。
    @discardableResult
    func renderDemoShot(to path: String) -> Bool {
        guard let content = window?.contentView, let tab = activeTab else { return false }
        content.layoutSubtreeIfNeeded()
        tab.textView.layoutManager?.ensureLayout(for: tab.textView.textContainer ?? NSTextContainer())
        tab.ruler.needsDisplay = true
        content.layoutSubtreeIfNeeded()

        let bounds = content.bounds
        guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        content.cacheDisplay(in: bounds, to: rep)

        // 手动补画行号:离屏渲染不走 NSScrollView 的标尺绘制管线。
        // rep 位图上下文为 y-up(已实验标定)。
        // 注意:wrap 模式下 container.size.height 是无穷大,不能用容器高度做基准,
        // 改用"第一行 maxY"锚定,其余行相对它偏移。
        if let ruler = tab.scrollView.verticalRulerView,
           let lm = tab.textView.layoutManager,
           let container = tab.textView.textContainer {
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current = context

            let tvFrame = tab.textView.convert(tab.textView.bounds, to: content) // y-up
            let numberRightX: CGFloat = 40           // 行号右对齐位置(标尺区 0..46,避开正文)
            let tvTopVisual = bounds.height - tvFrame.maxY
            let insetH = tab.textView.textContainerInset.height
            let docTopVisual = tvTopVisual + insetH                    // 第一行文字顶部视觉 y

            let index = { tab.rebuildIndexIfNeeded(); return tab.lineIndex }()
            let glyphRange = lm.glyphRange(for: container)
            let caretLine = index.lineNumber(at: tab.textView.selectedRange().location)
            let regularFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

            // 第一遍:收集(逻辑行, 片段 minY = 行顶距容器顶的视觉距离)
            // TextKit 布局的 fragRect.minY 就是视觉方向(从容器顶部向下增长)
            var fragments: [(line: Int, minY: CGFloat)] = []
            lm.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, fragGlyphs, _ in
                let charRange = lm.characterRange(forGlyphRange: fragGlyphs, actualGlyphRange: nil)
                let line = index.lineNumber(at: charRange.location)
                FileHandle.standardError.write("frag line=\(line) minY=\(fragRect.minY) maxY=\(fragRect.maxY) h=\(fragRect.height)\n".data(using: .utf8)!)
                fragments.append((line, fragRect.minY))
            }
            guard !fragments.isEmpty else {
                NSGraphicsContext.restoreGraphicsState()
                return false
            }
            var lastLine = -1
            for frag in fragments {
                guard frag.line != lastLine else { continue }
                lastLine = frag.line

                let visualY = docTopVisual + frag.minY                 // 行顶视觉 y(距窗口顶)
                let numberString = String(frag.line) as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: frag.line == caretLine
                        ? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
                        : regularFont,
                    .foregroundColor: frag.line == caretLine
                        ? NSColor.controlAccentColor
                        : NSColor.tertiaryLabelColor,
                ]
                let size = numberString.size(withAttributes: attrs)
                numberString.draw(
                    at: NSPoint(x: numberRightX - size.width,
                                y: bounds.height - visualY - size.height),
                    withAttributes: attrs)
            }
            NSGraphicsContext.restoreGraphicsState()

            // 恢复标尺配置(下次真实显示时按用户偏好)
            tab.scrollView.rulersVisible = Preferences.lineNumbersEnabled
            tab.scrollView.hasVerticalRuler = Preferences.lineNumbersEnabled
        }

        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }

    /// 切换激活标签(截图第二张用)
    func demoSelectTab(at index: Int) {
        activeIndex = index
        attachActiveTabView()
        if let tab = activeTab, tab.needsFullHighlight {
            applyHighlight(tab)
        }
        refreshAllUI()
    }

    // MARK: - 通用弹窗

    func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        if let win = window {
            alert.beginSheetModal(for: win, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        flushAll()
    }

    // MARK: - NSMenuItemValidation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleWrap):
            menuItem.state = Preferences.wrapEnabled ? .on : .off
        case #selector(toggleLineNumbers):
            menuItem.state = Preferences.lineNumbersEnabled ? .on : .off
        case #selector(toggleStatusBar):
            menuItem.state = Preferences.statusBarEnabled ? .on : .off
        case #selector(toggleOnTop):
            menuItem.state = Preferences.alwaysOnTop ? .on : .off
        case #selector(reloadActiveTab):
            menuItem.isEnabled = activeTab?.fileURL != nil
        case #selector(openRecentPath(_:)):
            menuItem.isEnabled = !Preferences.recentFiles.isEmpty
        case #selector(reopenLastClosedDoc):
            menuItem.isEnabled = !historyStore.entries.isEmpty
        case #selector(clearHistoryDocuments):
            menuItem.isEnabled = !historyStore.entries.isEmpty
        default:
            break
        }
        return true
    }
}
