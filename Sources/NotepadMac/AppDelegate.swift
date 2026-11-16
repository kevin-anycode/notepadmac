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

        // 窗口化演示模式:NOTEPADMAC_DEMO_WINDOWED(真实窗口 + 演示内容,数据仍隔离,
        // 供外部截屏展示菜单栏 / 弹窗 / 菜单)。NOTEPADMAC_DEMO_KEEP_HISTORY 保留预置历史
        if env["NOTEPADMAC_DEMO_WINDOWED"] != nil {
            // NOTEPADMAC_DEMO_APPEARANCE=dark|light:仅本应用呈现指定外观(不改系统设置)。
            // 必须在创建任何 UI 之前设置,否则部分视图按系统外观缓存颜色
            if let appearance = env["NOTEPADMAC_DEMO_APPEARANCE"] {
                let name: NSAppearance.Name = appearance == "dark" ? .darkAqua : .aqua
                NSApp.appearance = NSAppearance(named: name)
            }
            Preferences.ensureDirectories()
            let controller = MainWindowController()
            windowController = controller
            NSApp.mainMenu = MenuBuilder.build(controller: controller)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            controller.setupDemoContent(preserveHistory: env["NOTEPADMAC_DEMO_KEEP_HISTORY"] != nil)
            // 窗口贴靠菜单栏下方,方便外部截屏连菜单栏一起收录
            controller.demoPositionWindowUnderMenuBar()
            // NOTEPADMAC_DEMO_TAB=N:切到第 N 个标签(0 起)
            if let tabIndex = env["NOTEPADMAC_DEMO_TAB"].flatMap(Int.init) {
                controller.demoSelectTab(at: tabIndex)
            }
            // NOTEPADMAC_DEMO_REPLACE=1:查找条切换为替换模式并预填正则演示内容
            if env["NOTEPADMAC_DEMO_REPLACE"] != nil {
                controller.demoShowFind(query: "\\d+", replaceText: "$0.0", regex: true)
            }
            // NOTEPADMAC_DEMO_CONFIRM=1:弹出关闭标签的保存确认
            if env["NOTEPADMAC_DEMO_CONFIRM"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { controller.demoShowCloseConfirm() }
            }
            // NOTEPADMAC_DEMO_MENU=菜单名:展开菜单栏中的某项(如 编码)
            if let menuName = env["NOTEPADMAC_DEMO_MENU"] {
                controller.demoOpenMainMenu(named: menuName)
            }
            controller.focusActiveEditor()
            return
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

    /// 生成 README 产品截图(离屏渲染无需权限)。
    /// 每张截图由独立进程渲染(NOTEPADMAC_DEMO_VARIANT),避免多次渲染间
    /// 标尺/查找条布局状态串扰导致行号重影。
    private func runDemoScreenshotMode(outputDir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        let demoEnv = ProcessInfo.processInfo.environment

        func makeController() -> MainWindowController {
            let controller = MainWindowController()
            controller.setupDemoContent()
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return controller
        }

        // NOTEPADMAC_DEMO_TAB=N + NOTEPADMAC_DEMO_OUT=path:单标签验证路径
        if let tabIndex = demoEnv["NOTEPADMAC_DEMO_TAB"].flatMap(Int.init),
           let customOut = demoEnv["NOTEPADMAC_DEMO_OUT"] {
            if demoEnv["NOTEPADMAC_DEMO_APPEARANCE"] == "dark" {
                NSApp.appearance = NSAppearance(named: .darkAqua)
            }
            let controller = makeController()
            controller.demoSelectTab(at: tabIndex)
            let ok = controller.renderDemoShot(to: customOut)
            FileHandle.standardError.write("tab\(tabIndex): \(ok)\n".data(using: .utf8)!)
            exit(0)
        }

        let variant = demoEnv["NOTEPADMAC_DEMO_VARIANT"] ?? "main"
        NSApp.appearance = NSAppearance(named: variant == "dark" ? .darkAqua : .aqua)
        let controller = makeController()

        var extra = ""
        let ok: Bool
        switch variant {
        case "main":
            // 主视觉:随笔模式,Markdown 高亮 + 查找高亮 + 多标签 + 选区状态栏
            if let rep = controller.demoContentRep() {
                ok = controller.demoWrite(rep, to: outputDir + "/screenshot-main.png")
                let wroteBar = controller.demoCropStatusbar(from: rep, to: outputDir + "/screenshot-statusbar.png")
                extra = "statusbar: \(wroteBar)"
            } else {
                ok = false
            }
        case "code":
            // 代码模式:Swift 语法高亮 + 行号
            controller.closeFindBar()
            controller.demoSelectTab(at: 1)
            ok = controller.renderDemoShot(to: outputDir + "/screenshot-code.png")
        case "replace":
            // 查找替换:正则 + 全部匹配高亮 + 替换栏
            controller.demoShowFind(query: "\\d+", replaceText: "$0.0", regex: true)
            ok = controller.renderDemoShot(to: outputDir + "/screenshot-replace.png")
        case "dark":
            // 深色模式:代码高亮跟随系统
            controller.closeFindBar()
            controller.demoSelectTab(at: 1)
            ok = controller.renderDemoShot(to: outputDir + "/screenshot-dark.png")
        default:
            FileHandle.standardError.write("unknown demo variant: \(variant)\n".data(using: .utf8)!)
            exit(2)
        }
        FileHandle.standardError.write("variant \(variant): \(ok)\(extra.isEmpty ? "" : " , " + extra)\n".data(using: .utf8)!)
        exit(ok ? 0 : 1)
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
