import Foundation
import AppKit

/// 应用偏好设置(UserDefaults 持久化)。
enum Preferences {
    static let defaults = UserDefaults.standard

    private static let prefix = "NotepadMac."

    // MARK: 字体

    static var fontName: String {
        get { defaults.string(forKey: prefix + "font.name") ?? "Menlo" }
        set { defaults.set(newValue, forKey: prefix + "font.name") }
    }

    static var fontSize: CGFloat {
        get { defaults.object(forKey: prefix + "font.size") as? CGFloat ?? 13 }
        set { defaults.set(newValue, forKey: prefix + "font.size") }
    }

    static var editorFont: NSFont {
        NSFont(name: fontName, size: fontSize)
            ?? NSFont.userFont(ofSize: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize)
    }

    // MARK: 视图开关

    static var wrapEnabled: Bool {
        get { defaults.object(forKey: prefix + "wrap.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: prefix + "wrap.enabled") }
    }

    static var lineNumbersEnabled: Bool {
        get { defaults.object(forKey: prefix + "lineNumbers.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: prefix + "lineNumbers.enabled") }
    }

    static var statusBarEnabled: Bool {
        get { defaults.object(forKey: prefix + "statusBar.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: prefix + "statusBar.enabled") }
    }

    static var alwaysOnTop: Bool {
        get { defaults.bool(forKey: prefix + "alwaysOnTop") }
        set { defaults.set(newValue, forKey: prefix + "alwaysOnTop") }
    }

    // MARK: 最近打开

    static var recentFiles: [String] {
        get { defaults.stringArray(forKey: prefix + "recent.files") ?? [] }
        set { defaults.set(newValue, forKey: prefix + "recent.files") }
    }

    static func addRecentFile(_ path: String) {
        var list = recentFiles
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        if list.count > 10 { list = Array(list.prefix(10)) }
        recentFiles = list
    }

    // MARK: 数据目录

    /// ~/Library/Application Support/NotepadMac
    /// 演示截图模式(NOTEPADMAC_DEMO_ROOT 存在时)重定向到临时目录,不触碰真实数据
    static var appSupportDir: URL {
        if let demoRoot = ProcessInfo.processInfo.environment["NOTEPADMAC_DEMO_ROOT"] {
            return URL(fileURLWithPath: demoRoot, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NotepadMac", isDirectory: true)
    }

    static var draftsDir: URL {
        appSupportDir.appendingPathComponent("drafts", isDirectory: true)
    }

    /// 确保数据目录存在(应用启动时调用一次)。
    static func ensureDirectories() {
        let fm = FileManager.default
        for dir in [appSupportDir, draftsDir] {
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }
}
