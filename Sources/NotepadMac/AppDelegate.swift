import AppKit
import NotepadCore

/// 应用生命周期:窗口创建、菜单装配、Finder 打开文件事件、退出前落盘。
final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var windowController: MainWindowController?
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 演示截图模式:NOTEPADMAC_DEMO_ROOT(隔离数据目录) + NOTEPADMAC_DEMO_SCREENSHOT(输出目录)
        let env = ProcessInfo.processInfo.environment
        FileHandle.standardError.write("didFinishLaunching, demo dir=\(env["NOTEPADMAC_DEMO_SCREENSHOT"] ?? "nil")\n".data(using: .utf8)!)
        if let shotDir = env["NOTEPADMAC_DEMO_SCREENSHOT"], env["NOTEPADMAC_DEMO_ROOT"] != nil {
            runDemoScreenshotMode(outputDir: shotDir)
            exit(0)
        }

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

    /// 生成 README 产品截图(两张:随笔 + Markdown 高亮 / 代码高亮),离屏渲染无需权限
    private func runDemoScreenshotMode(outputDir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        // 外观:NOTEPADMAC_DEMO_APPEARANCE=dark 渲染深色主题(验证深色模式用),默认浅色
        let demoEnv = ProcessInfo.processInfo.environment
        if demoEnv["NOTEPADMAC_DEMO_APPEARANCE"] == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else {
            NSApp.appearance = NSAppearance(named: .aqua) // README 使用浅色主题
        }

        let controller = MainWindowController()
        controller.setupDemoContent()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)

        // NOTEPADMAC_DEMO_TAB=N + NOTEPADMAC_DEMO_OUT=path:只截指定标签(深色验证用)
        if let tabIndex = demoEnv["NOTEPADMAC_DEMO_TAB"].flatMap(Int.init),
           let customOut = demoEnv["NOTEPADMAC_DEMO_OUT"] {
            controller.demoSelectTab(at: tabIndex)
            let ok = controller.renderDemoShot(to: customOut)
            FileHandle.standardError.write("tab\(tabIndex): \(ok)\n".data(using: .utf8)!)
            exit(0)
        }

        let okMain = controller.renderDemoShot(to: outputDir + "/screenshot-main.png")
        controller.closeFindBar()
        controller.demoSelectTab(at: 1)
        let okCode = controller.renderDemoShot(to: outputDir + "/screenshot-code.png")
        FileHandle.standardError.write("main: \(okMain), code: \(okCode)\n".data(using: .utf8)!)
        exit(0)
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
