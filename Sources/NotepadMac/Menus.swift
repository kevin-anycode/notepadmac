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

/// 主菜单构建:全中文,快捷键兼顾 Notepad++ 习惯与 macOS 惯例。
enum MenuBuilder {

    /// 历史条目的关闭时间:精确到分钟,保证连续关闭时顺序肉眼可辨
    private static func historyTimeText(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            df.dateFormat = "今天 HH:mm"
            return df.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            df.dateFormat = "'昨天' HH:mm"
            return df.string(from: date)
        }
        df.dateFormat = "M月d日 HH:mm"
        return df.string(from: date)
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
                let item = NSMenuItem(title: "(暂无历史文档)", action: nil, keyEquivalent: "")
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
                let moreItem = NSMenuItem(title: "更多历史(\(store.entries.count - visibleCount) 条)",
                                          action: nil, keyEquivalent: "")
                let moreMenu = NSMenu(title: "更多历史")
                for entry in store.entries.dropFirst(visibleCount) {
                    moreMenu.addItem(entryItem(entry))
                }
                moreItem.submenu = moreMenu
                menu.addItem(moreItem)
            }

            menu.addItem(.separator())
            menu.add(title: "清空历史文档",
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
                let item = NSMenuItem(title: "(空)", action: nil, keyEquivalent: "")
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
                let clear = NSMenuItem(title: "清空最近打开",
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
        appMenu.add(title: "关于 NotepadMac", action: #selector(MainWindowController.showAbout)).target = controller
        appMenu.addItem(.separator())
        appMenu.add(title: "打开数据目录…", action: #selector(MainWindowController.openDataFolder)).target = controller
        appMenu.add(title: "字体…", action: #selector(MainWindowController.openFontPanel), keyEquivalent: "t").target = controller
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.add(title: "隐藏 NotepadMac", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.add(title: "隐藏其他",
                                     action: #selector(NSApplication.hideOtherApplications(_:)),
                                     keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.add(title: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)))
        appMenu.addItem(.separator())
        appMenu.add(title: "退出 NotepadMac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(title: "NotepadMac", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // MARK: 文件
        let file = NSMenu(title: "文件")
        file.add(title: "新建标签", action: #selector(MainWindowController.newDraftTab), keyEquivalent: "n").target = controller
        file.add(title: "打开…", action: #selector(MainWindowController.openFilesPanel), keyEquivalent: "o").target = controller
        let recentsItem = NSMenuItem(title: "最近打开", action: nil, keyEquivalent: "")
        let recentsMenu = NSMenu(title: "最近打开")
        let provider = RecentsMenuProvider()
        provider.controller = controller
        recentsMenu.delegate = provider
        // NSMenuDelegate 是 weak 引用,用关联对象保活
        objc_setAssociatedObject(recentsMenu, &recentProviderKey, provider, .OBJC_ASSOCIATION_RETAIN)
        recentsItem.submenu = recentsMenu
        file.addItem(recentsItem)

        // 历史文档(关闭过的文档留底,默认显示 10 条,上限 50 条)
        let reopenLast = file.add(title: "重新打开上次关闭的文档",
                                  action: #selector(MainWindowController.reopenLastClosedDoc),
                                  keyEquivalent: "T")
        reopenLast.keyEquivalentModifierMask = [.command, .shift]
        reopenLast.target = controller
        let historyItem = NSMenuItem(title: "历史文档", action: nil, keyEquivalent: "")
        let historyMenu = NSMenu(title: "历史文档")
        let historyProvider = HistoryMenuProvider()
        historyProvider.controller = controller
        historyMenu.delegate = historyProvider
        objc_setAssociatedObject(historyMenu, &historyProviderKey, historyProvider, .OBJC_ASSOCIATION_RETAIN)
        historyItem.submenu = historyMenu
        file.addItem(historyItem)
        file.addItem(.separator())
        file.add(title: "保存", action: #selector(MainWindowController.saveNow), keyEquivalent: "s").target = controller
        let saveAs = file.add(title: "另存为…", action: #selector(MainWindowController.saveCurrentAs), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        saveAs.target = controller
        file.add(title: "从磁盘重新加载", action: #selector(MainWindowController.reloadActiveTab)).target = controller
        file.addItem(.separator())
        file.add(title: "关闭标签", action: #selector(MainWindowController.closeActiveTab), keyEquivalent: "w").target = controller
        let closeWindow = file.add(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        main.addItem(fileItem)

        // MARK: 编辑
        let edit = NSMenu(title: "编辑")
        edit.add(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.add(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.add(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.add(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.add(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.add(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.add(title: "插入时间戳", action: #selector(MainWindowController.insertTimestamp), keyEquivalent: ";").target = controller
        edit.addItem(.separator())
        edit.add(title: "转换为小写", action: #selector(MainWindowController.lowercaseSelection)).target = controller
        edit.add(title: "转换为大写", action: #selector(MainWindowController.uppercaseSelection)).target = controller
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)

        // MARK: 查找
        let find = NSMenu(title: "查找")
        find.add(title: "查找…", action: #selector(MainWindowController.showFind), keyEquivalent: "f").target = controller
        find.add(title: "查找下一个", action: #selector(MainWindowController.findNext), keyEquivalent: "g").target = controller
        let findPrev = find.add(title: "查找上一个", action: #selector(MainWindowController.findPrevious), keyEquivalent: "g")
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        findPrev.target = controller
        let replace = find.add(title: "替换…", action: #selector(MainWindowController.showReplace), keyEquivalent: "f")
        replace.keyEquivalentModifierMask = [.command, .option]
        replace.target = controller
        find.addItem(.separator())
        find.add(title: "跳转到行…", action: #selector(MainWindowController.gotoLine), keyEquivalent: "l").target = controller
        let findItem = NSMenuItem(title: "查找", action: nil, keyEquivalent: "")
        findItem.submenu = find
        main.addItem(findItem)

        // MARK: 视图
        let view = NSMenu(title: "视图")
        view.add(title: "放大", action: #selector(MainWindowController.zoomIn), keyEquivalent: "=").target = controller
        view.add(title: "缩小", action: #selector(MainWindowController.zoomOut), keyEquivalent: "-").target = controller
        view.add(title: "实际大小", action: #selector(MainWindowController.resetFontSize), keyEquivalent: "0").target = controller
        view.addItem(.separator())
        let wrap = view.add(title: "自动换行", action: #selector(MainWindowController.toggleWrap))
        wrap.keyEquivalentModifierMask = [.command, .option]
        wrap.target = controller
        view.add(title: "显示行号", action: #selector(MainWindowController.toggleLineNumbers)).target = controller
        view.add(title: "显示状态栏", action: #selector(MainWindowController.toggleStatusBar)).target = controller
        view.add(title: "窗口置顶", action: #selector(MainWindowController.toggleOnTop)).target = controller
        let viewItem = NSMenuItem(title: "视图", action: nil, keyEquivalent: "")
        viewItem.submenu = view
        main.addItem(viewItem)

        // MARK: 编码
        let encoding = NSMenu(title: "编码")
        for enc in TextEncoding.allCases {
            let item = encoding.add(title: "转换为 \(enc.displayName)",
                                    action: #selector(MainWindowController.convertEncodingTo(_:)))
            item.representedObject = enc.rawValue
            item.target = controller
        }
        let encodingItem = NSMenuItem(title: "编码", action: nil, keyEquivalent: "")
        encodingItem.submenu = encoding
        main.addItem(encodingItem)

        // MARK: 换行符
        let eol = NSMenu(title: "换行符")
        for e in LineEnding.allCases {
            let item = eol.add(title: "转换为 \(e.displayName)",
                               action: #selector(MainWindowController.convertEOLTo(_:)))
            item.representedObject = e.rawValue
            item.target = controller
        }
        let eolItem = NSMenuItem(title: "换行符", action: nil, keyEquivalent: "")
        eolItem.submenu = eol
        main.addItem(eolItem)

        // MARK: 语言
        let language = NSMenu(title: "语言")
        for lang in ProgLanguage.allCases {
            let item = language.add(title: lang.displayName,
                                    action: #selector(MainWindowController.setLanguageTo(_:)))
            item.representedObject = lang.rawValue
            item.target = controller
        }
        let languageItem = NSMenuItem(title: "语言", action: nil, keyEquivalent: "")
        languageItem.submenu = language
        main.addItem(languageItem)

        // MARK: 标签
        let tabs = NSMenu(title: "标签")
        let nextTab = tabs.add(title: "下一个标签",
                               action: #selector(MainWindowController.selectNextTab),
                               keyEquivalent: "\t")
        nextTab.keyEquivalentModifierMask = [.control]
        nextTab.target = controller
        let prevTab = tabs.add(title: "上一个标签",
                               action: #selector(MainWindowController.selectPreviousTab),
                               keyEquivalent: "\t")
        prevTab.keyEquivalentModifierMask = [.control, .shift]
        prevTab.target = controller
        tabs.addItem(.separator())
        tabs.add(title: "关闭其他标签", action: #selector(MainWindowController.closeOtherTabs)).target = controller
        tabs.add(title: "关闭全部标签", action: #selector(MainWindowController.closeAllTabs)).target = controller
        let tabsItem = NSMenuItem(title: "标签", action: nil, keyEquivalent: "")
        tabsItem.submenu = tabs
        main.addItem(tabsItem)

        // MARK: 窗口
        let window = NSMenu(title: "窗口")
        window.add(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.add(title: "缩放窗口", action: #selector(NSWindow.performZoom(_:)))
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        // MARK: 帮助
        let help = NSMenu(title: "帮助")
        help.add(title: "关于 NotepadMac", action: #selector(MainWindowController.showAbout)).target = controller
        help.add(title: "打开数据目录…", action: #selector(MainWindowController.openDataFolder)).target = controller
        let helpItem = NSMenuItem(title: "帮助", action: nil, keyEquivalent: "")
        helpItem.submenu = help
        main.addItem(helpItem)
        NSApp.helpMenu = help

        return main
    }
}

private var recentProviderKey: UInt8 = 0
private var historyProviderKey: UInt8 = 0
