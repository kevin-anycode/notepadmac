import Foundation
import NotepadCore

// MARK: - 会话模型(Codable)

struct SessionTabState: Codable {
    /// 命名文件路径;草稿为 nil
    var filePath: String?
    /// 草稿/快照文件 UUID
    var draftID: String
    /// 显示名(草稿名需要保留)
    var displayName: String
    var encoding: String
    var eol: String
    var language: String
    var cursorLocation: Int
    var scrollFraction: Double
    /// 是否存在未写入原文件的修改(自动备份不写原文件,靠此字段跨重启恢复未保存状态)。
    /// Optional 以兼容旧版 session.json(缺字段时解码为 nil)
    var hasUnsavedChanges: Bool?
}

struct SessionState: Codable {
    var version: Int = 1
    var tabs: [SessionTabState] = []
    var activeIndex: Int = 0
    /// 窗口框 NSStringFromRect
    var windowFrame: String = ""
}

// MARK: - 会话存储

/// 管理 session.json 与 drafts/ 目录。
final class SessionStore {

    let sessionURL: URL
    let draftsDir: URL

    init() {
        Preferences.ensureDirectories()
        sessionURL = Preferences.appSupportDir.appendingPathComponent("session.json")
        draftsDir = Preferences.draftsDir
    }

    // MARK: 会话

    func loadSession() -> SessionState? {
        guard let data = try? Data(contentsOf: sessionURL) else { return nil }
        let decoder = JSONDecoder()
        guard let state = try? decoder.decode(SessionState.self, from: data) else { return nil }
        return state
    }

    func saveSession(_ state: SessionState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        // 原子写,避免崩溃时 session.json 半截
        try? data.write(to: sessionURL, options: .atomic)
    }

    // MARK: 草稿

    func draftURL(id: String) -> URL {
        draftsDir.appendingPathComponent(id + ".txt")
    }

    func readDraft(id: String) -> String? {
        let url = draftURL(id: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func removeDraft(id: String) {
        try? FileManager.default.removeItem(at: draftURL(id: id))
    }

    /// 把 EditorTab 的状态序列化。
    static func tabState(from tab: EditorTab) -> SessionTabState {
        SessionTabState(
            filePath: tab.fileURL?.path,
            draftID: tab.id.uuidString,
            displayName: tab.displayName,
            encoding: tab.encoding.rawValue,
            eol: tab.eol.rawValue,
            language: tab.language.rawValue,
            cursorLocation: tab.cursorLocation,
            scrollFraction: tab.scrollFraction,
            hasUnsavedChanges: tab.isDirty)
    }

    /// 从会话状态恢复一个标签(文件 → 快照回退链)。
    /// 若记录了未保存修改(hasUnsavedChanges),内容以自动备份的快照为准并保持"未保存"状态。
    static func restoreTab(from state: SessionTabState, store: SessionStore) -> EditorTab? {
        var restored: EditorTab?

        // 1. 优先读命名文件
        if let path = state.filePath {
            let url = URL(fileURLWithPath: path)
            if let tab = EditorTab.open(url: url) {
                tab.encoding = TextEncoding(rawValue: state.encoding) ?? tab.encoding
                tab.eol = LineEnding(rawValue: state.eol) ?? tab.eol
                if state.hasUnsavedChanges == true, let snapshot = store.readDraft(id: state.draftID) {
                    // 有未保存的修改:内容以快照为准(磁盘版是旧的),保持脏标记
                    // 把磁盘现状记为基线,避免误触发"外部修改"检测
                    tab.restoreContent(snapshot)
                    tab.isDirty = true
                    tab.lastWrittenMtime = tab.currentFileMtime()
                }
                tab.pendingCursorLocation = state.cursorLocation
                tab.pendingScrollFraction = state.scrollFraction
                restored = tab
            } else if let content = store.readDraft(id: state.draftID) {
                // 2. 文件没了:回退到快照(这就是"退出重开必然有记录"的兜底)
                let tab = EditorTab.newDraft(name: state.displayName + "(已从快照恢复)")
                tab.encoding = TextEncoding(rawValue: state.encoding) ?? .utf8
                tab.eol = LineEnding(rawValue: state.eol) ?? .lf
                tab.language = ProgLanguage(rawValue: state.language) ?? .plain
                tab.restoreContent(content)
                tab.isDirty = true
                tab.pendingCursorLocation = state.cursorLocation
                tab.pendingScrollFraction = state.scrollFraction
                restored = tab
            }
        } else if let content = store.readDraft(id: state.draftID) {
            // 3. 纯草稿
            let tab = EditorTab.newDraft(name: state.displayName)
            tab.encoding = TextEncoding(rawValue: state.encoding) ?? .utf8
            tab.eol = LineEnding(rawValue: state.eol) ?? .lf
            tab.language = ProgLanguage(rawValue: state.language) ?? .plain
            tab.restoreContent(content)
            tab.isDirty = state.hasUnsavedChanges ?? true
            tab.pendingCursorLocation = state.cursorLocation
            tab.pendingScrollFraction = state.scrollFraction
            restored = tab
        }

        // 恢复成功后旧草稿已迁移到新标签的草稿文件,清理旧文件
        if restored != nil {
            store.removeDraft(id: state.draftID)
        }
        return restored
    }
}
