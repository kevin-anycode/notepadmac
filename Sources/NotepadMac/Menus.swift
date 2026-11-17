import AppKit
import NotepadCore

// MARK: - 菜单构建辅助

extension NSMenu {
    @discardableResult
    func add(title: String, action: Selector?, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        addItem(item)
        return item
    }
}

/// 主菜单构建:快捷键兼顾 Notepad++ 习惯与 macOS 惯例。
/// 文案全部走本地化(key = 英文原文,中文翻译见 Resources/zh-Hans.lproj)。
enum MenuBuilder {

    /// 历史条目的关闭时间:精确到分钟,保证连续关闭时顺序肉眼可辨
    private static func historyTimeText(_ date: Date) -> String {
        let cal = Calendar.current
        let timeDF = DateFormatter()
        timeDF.dateFormat = "HH:mm"
        let timeText = timeDF.string(from: date)
        if cal.isDateInToday(date) {
            return LF("Today %@", timeText)
        }
        if cal.isDateInYesterday(date) {
            return LF("Yesterday %@", timeText)
        }
        let monthDay = DateFormatter()
        monthDay.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(monthDay.string(from: date)) \(timeText)"
    }

    /// 历史文档子菜单的动态刷新:默认列最近 10 条,其余进「更多历史」(上限 50 条)。
    /// 排序:最后关闭的永远在最上面(record 插入列表顶部)。
    final class HistoryMenuProvider: NSObject, NSMenuDelegate {
        weak var controller: MainWindowController?

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let controller = controller else { return }
            let store = controller.historyStore

            guard !store.entries.isEmpty else {
                let item = NSMenuItem(title: L("(No History)"), action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                return
            }

            func entryItem(_ entry: HistoryEntry) -> NSMenuItem {
                let time = MenuBuilder.historyTimeText(entry.savedAt)
                let item = NSMenuItem(title: "\(entry.title)  ·  \(time)",
                                      action: #selector(MainWindowController.openHistoryEntryFromMenu(_:)),
                                      keyEquivalent: "")
                item.target = controller
                item.representedObject = entry.id.uuidString
                return item
            }

            // 默认显示最近 10 条
            let visibleCount = min(HistoryStore.defaultVisibleEntries, store.entries.count)
            for entry in store.entries.prefix(visibleCount) {
                menu.addItem(entryItem(entry))
            }

            // 其余条目收纳进「更多历史」子菜单(总数最多 50)
            if store.entries.count > visibleCount {
                menu.addItem(.separator())
                let moreItem = NSMenuItem(title: LF("More History (%d)", store.entries.count - visibleCount),
                                          action: nil, keyEquivalent: "")
                let moreMenu = NSMenu(title: L("More History"))
                for entry in store.entries.dropFirst(visibleCount) {
                    moreMenu.addItem(entryItem(entry))
                }
                moreItem.submenu = moreMenu
                menu.addItem(moreItem)
            }

            menu.addItem(.separator())
            menu.add(title: L("Clear History Documents"),
                     action: #selector(MainWindowController.clearHistoryDocuments)).target = controller
        }
    }

    /// 最近打开菜单的动态刷新代理
    final class RecentsMenuProvider: NSObject, NSMenuDelegate {
        weak var controller: MainWindowController?

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let recents = Preferences.recentFiles
            if recents.isEmpty {
                let item = NSMenuItem(title: L("(Empty)"), action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else {
                for path in recents {
                    let item = NSMenuItem(title: path,
                                          action: #selector(MainWindowController.openRecentPath(_:)),
                                          keyEquivalent: "")
                    item.target = controller
                    item.representedObject = path
                    menu.addItem(item)
                }
                menu.addItem(.separator())
                let clear = NSMenuItem(title: L("Clear Recent Files"),
                                       action: #selector(MainWindowController.clearRecentFiles),
                                       keyEquivalent: "")
                clear.target = controller
                menu.addItem(clear)
            }
        }
    }

    static func build(controller: MainWindowController) -> NSMenu {
        let main = NSMenu()

        // MARK: 应用菜单(第一项固定为应用名)
        let appMenu = NSMenu()
        appMenu.add(title: L("About NotepadMac"), action: #selector(MainWindowController.showAbout)).target = controller
        appMenu.addItem(.separator())
        appMenu.add(title: L("Open Data Directory…"), action: #selector(MainWindowController.openDataFolder)).target = controller
        appMenu.add(title: L("Font…"), action: #selector(MainWindowController.openFontPanel), keyEquivalent: "t").target = controller
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: L("Services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.add(title: L("Hide NotepadMac"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.add(title: L("Hide Others"),
                                     action: #selector(NSApplication.hideOtherApplications(_:)),
                                     keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.add(title: L("Show All"), action: #selector(NSApplication.unhideAllApplications(_:)))
        appMenu.addItem(.separator())
        appMenu.add(title: L("Quit NotepadMac"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(title: "NotepadMac", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // MARK: 文件
        let file = NSMenu(title: L("File"))
        file.add(title: L("New Tab"), action: #selector(MainWindowController.newDraftTab), keyEquivalent: "n").target = controller
        file.add(title: L("Open…"), action: #selector(MainWindowController.openFilesPanel), keyEquivalent: "o").target = controller
        let recentsItem = NSMenuItem(title: L("Open Recent"), action: nil, keyEquivalent: "")
        let recentsMenu = NSMenu(title: L("Open Recent"))
        let provider = RecentsMenuProvider()
        provider.controller = controller
        recentsMenu.delegate = provider
        // NSMenuDelegate 是 weak 引用,用关联对象保活
        objc_setAssociatedObject(recentsMenu, &recentProviderKey, provider, .OBJC_ASSOCIATION_RETAIN)
        recentsItem.submenu = recentsMenu
        file.addItem(recentsItem)

        // 历史文档(关闭过的文档留底,默认显示 10 条,上限 50 条)
        let reopenLast = file.add(title: L("Reopen Last Closed Document"),
                                  action: #selector(MainWindowController.reopenLastClosedDoc),
                                  keyEquivalent: "T")
        reopenLast.keyEquivalentModifierMask = [.command, .shift]
        reopenLast.target = controller
        let historyItem = NSMenuItem(title: L("History Documents"), action: nil, keyEquivalent: "")
        let historyMenu = NSMenu(title: L("History Documents"))
        let historyProvider = HistoryMenuProvider()
        historyProvider.controller = controller
        historyMenu.delegate = historyProvider
        objc_setAssociatedObject(historyMenu, &historyProviderKey, historyProvider, .OBJC_ASSOCIATION_RETAIN)
        historyItem.submenu = historyMenu
        file.addItem(historyItem)
        file.addItem(.separator())
        file.add(title: L("Save"), action: #selector(MainWindowController.saveNow), keyEquivalent: "s").target = controller
        let saveAs = file.add(title: L("Save As…"), action: #selector(MainWindowController.saveCurrentAs), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        saveAs.target = controller
        file.add(title: L("Reload from Disk"), action: #selector(MainWindowController.reloadActiveTab)).target = controller
        file.addItem(.separator())
        file.add(title: L("Close Tab"), action: #selector(MainWindowController.closeActiveTab), keyEquivalent: "w").target = controller
        let closeWindow = file.add(title: L("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        let fileItem = NSMenuItem(title: L("File"), action: nil, keyEquivalent: "")
        fileItem.submenu = file
        main.addItem(fileItem)

        // MARK: 编辑
        let edit = NSMenu(title: L("Edit"))
        edit.add(title: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.add(title: L("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.add(title: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.add(title: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.add(title: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.add(title: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.add(title: L("Insert Timestamp"), action: #selector(MainWindowController.insertTimestamp), keyEquivalent: ";").target = controller
        edit.addItem(.separator())
        edit.add(title: L("Convert to Lowercase"), action: #selector(MainWindowController.lowercaseSelection)).target = controller
        edit.add(title: L("Convert to Uppercase"), action: #selector(MainWindowController.uppercaseSelection)).target = controller
        let editItem = NSMenuItem(title: L("Edit"), action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)

        // MARK: 查找
        let find = NSMenu(title: L("Find"))
        find.add(title: L("Find…"), action: #selector(MainWindowController.showFind), keyEquivalent: "f").target = controller
        find.add(title: L("Find Next"), action: #selector(MainWindowController.findNext), keyEquivalent: "g").target = controller
        let findPrev = find.add(title: L("Find Previous"), action: #selector(MainWindowController.findPrevious), keyEquivalent: "g")
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        findPrev.target = controller
        let replace = find.add(title: L("Replace…"), action: #selector(MainWindowController.showReplace), keyEquivalent: "f")
        replace.keyEquivalentModifierMask = [.command, .option]
        replace.target = controller
        find.addItem(.separator())
        find.add(title: L("Go to Line…"), action: #selector(MainWindowController.gotoLine), keyEquivalent: "l").target = controller
        let findItem = NSMenuItem(title: L("Find"), action: nil, keyEquivalent: "")
        findItem.submenu = find
        main.addItem(findItem)

        // MARK: 视图
        let view = NSMenu(title: L("View"))
        view.add(title: L("Zoom In"), action: #selector(MainWindowController.zoomIn), keyEquivalent: "=").target = controller
        view.add(title: L("Zoom Out"), action: #selector(MainWindowController.zoomOut), keyEquivalent: "-").target = controller
        view.add(title: L("Actual Size"), action: #selector(MainWindowController.resetFontSize), keyEquivalent: "0").target = controller
        view.addItem(.separator())
        let wrap = view.add(title: L("Word Wrap"), action: #selector(MainWindowController.toggleWrap))
        wrap.keyEquivalentModifierMask = [.command, .option]
        wrap.target = controller
        view.add(title: L("Show Line Numbers"), action: #selector(MainWindowController.toggleLineNumbers)).target = controller
        view.add(title: L("Show Status Bar"), action: #selector(MainWindowController.toggleStatusBar)).target = controller
        view.add(title: L("Keep Window on Top"), action: #selector(MainWindowController.toggleOnTop)).target = controller
        let viewItem = NSMenuItem(title: L("View"), action: nil, keyEquivalent: "")
        viewItem.submenu = view
        main.addItem(viewItem)

        // MARK: 编码
        let encoding = NSMenu(title: L("Encoding"))
        for enc in TextEncoding.allCases {
            let item = encoding.add(title: LF("Convert to %@", enc.displayName),
                                    action: #selector(MainWindowController.convertEncodingTo(_:)))
            item.representedObject = enc.rawValue
            item.target = controller
        }
        let encodingItem = NSMenuItem(title: L("Encoding"), action: nil, keyEquivalent: "")
        encodingItem.submenu = encoding
        main.addItem(encodingItem)

        // MARK: 换行符
        let eol = NSMenu(title: L("Line Endings"))
        for e in LineEnding.allCases {
            let item = eol.add(title: LF("Convert to %@", e.displayName),
                               action: #selector(MainWindowController.convertEOLTo(_:)))
            item.representedObject = e.rawValue
            item.target = controller
        }
        let eolItem = NSMenuItem(title: L("Line Endings"), action: nil, keyEquivalent: "")
        eolItem.submenu = eol
        main.addItem(eolItem)

        // MARK: 语言
        let language = NSMenu(title: L("Language"))
        for lang in ProgLanguage.allCases {
            let item = language.add(title: lang.displayName,
                                    action: #selector(MainWindowController.setLanguageTo(_:)))
            item.representedObject = lang.rawValue
            item.target = controller
        }
        let languageItem = NSMenuItem(title: L("Language"), action: nil, keyEquivalent: "")
        languageItem.submenu = language
        main.addItem(languageItem)

        // MARK: 标签
        let tabs = NSMenu(title: L("Tabs"))
        let nextTab = tabs.add(title: L("Next Tab"),
                               action: #selector(MainWindowController.selectNextTab),
                               keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        nextTab.target = controller
        let prevTab = tabs.add(title: L("Previous Tab"),
                               action: #selector(MainWindowController.selectPreviousTab),
                               keyEquivalent: "\t")
        prevTab.keyEquivalentModifierMask = [.control, .shift]
        prevTab.target = controller
        tabs.addItem(.separator())
        tabs.add(title: L("Close Other Tabs"), action: #selector(MainWindowController.closeOtherTabs)).target = controller
        tabs.add(title: L("Close All Tabs"), action: #selector(MainWindowController.closeAllTabs)).target = controller
        let tabsItem = NSMenuItem(title: L("Tabs"), action: nil, keyEquivalent: "")
        tabsItem.submenu = tabs
        main.addItem(tabsItem)

        // MARK: 窗口
        let window = NSMenu(title: L("Window"))
        window.add(title: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.add(title: L("Zoom Window"), action: #selector(NSWindow.performZoom(_:)))
        let windowItem = NSMenuItem(title: L("Window"), action: nil, keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        // MARK: 帮助
        let help = NSMenu(title: L("Help"))
        help.add(title: L("About NotepadMac"), action: #selector(MainWindowController.showAbout)).target = controller
        help.add(title: L("Open Data Directory…"), action: #selector(MainWindowController.openDataFolder)).target = controller
        let helpItem = NSMenuItem(title: L("Help"), action: nil, keyEquivalent: "")
        helpItem.submenu = help
        main.addItem(helpItem)
        NSApp.helpMenu = help

        return main
    }
}

private var recentProviderKey: UInt8 = 0
private var historyProviderKey: UInt8 = 0
