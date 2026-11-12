import AppKit
import NotepadCore

/// 应用生命周期:窗口创建、菜单装配、Finder 打开文件事件、退出前落盘。
final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var windowController: MainWindowController?
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.ensureDirectories()

        let controller = MainWindowController()
        windowController = controller

        NSApp.mainMenu = MenuBuilder.build(controller: controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 窗口就绪后把焦点交给编辑区,启动即可直接打字
        controller.focusActiveEditor()

        if !pendingOpenURLs.isEmpty {
            controller.openFiles(urls: pendingOpenURLs)
            pendingOpenURLs = []
        }
    }

    // MARK: Finder「打开方式」/ 双击文件 / 拖到 Dock 图标

    func application(_ application: NSApplication, open urls: [URL]) {
        if let controller = windowController {
            controller.openFiles(urls: urls)
        } else {
            pendingOpenURLs = urls
        }
    }

    // MARK: 退出:有未写盘修改时先确认,再同步落盘

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = windowController else { return .terminateNow }
        return controller.confirmTerminate() ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            windowController?.showWindow(nil)
            windowController?.window?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}
