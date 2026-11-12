import Foundation

/// 单条历史文档记录
struct HistoryEntry: Codable {
    let id: UUID
    var title: String
    /// 来源文件路径;草稿为 nil
    var filePath: String?
    var savedAt: Date
    var encoding: String
    var eol: String
    var language: String
    /// 内容快照文件名(相对 History 目录)
    var snapshotFile: String
}

/// 历史文档存储:关闭标签时自动留底,上限 50 条(旧的淘汰),命名文件按路径去重。
/// 内容快照独立成文件(history/<UUID>.txt),元数据存 history.json。
final class HistoryStore {

    static let maxEntries = 50
    static let defaultVisibleEntries = 10

    private(set) var entries: [HistoryEntry] = []
    private let dir: URL
    private let indexURL: URL

    /// baseURL 供测试注入临时目录;默认应用数据目录
    init(baseURL: URL? = nil) {
        let root = baseURL ?? Preferences.appSupportDir
        dir = root.appendingPathComponent("History", isDirectory: true)
        indexURL = dir.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    // MARK: 读写

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        entries = (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// 读取条目的内容快照
    func content(of entry: HistoryEntry) -> String? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(entry.snapshotFile)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: 记录

    /// 关闭标签时记录。命名文件按路径去重(再次关闭同一路径时旧条目前移刷新)。
    @discardableResult
    func record(tab: EditorTab, content: String) -> Bool {
        if let path = tab.fileURL?.path {
            entries.removeAll { $0.filePath == path }
        }
        let entry = HistoryEntry(
            id: UUID(),
            title: tab.displayName,
            filePath: tab.fileURL?.path,
            savedAt: Date(),
            encoding: tab.encoding.rawValue,
            eol: tab.eol.rawValue,
            language: tab.language.rawValue,
            snapshotFile: UUID().uuidString + ".txt")
        let url = dir.appendingPathComponent(entry.snapshotFile)
        guard let data = content.data(using: .utf8),
              (try? data.write(to: url, options: .atomic)) != nil else { return false }
        entries.insert(entry, at: 0)
        trim()
        save()
        return true
    }

    /// 超出上限时淘汰最旧条目(连同快照文件)
    private func trim() {
        while entries.count > Self.maxEntries {
            let last = entries.removeLast()
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(last.snapshotFile))
        }
    }

    // MARK: 删除

    func remove(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: idx)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(entry.snapshotFile))
        save()
    }

    // 注:打开历史条目不移除条目 —— 历史是档案,可反复恢复;
    // 体量由 50 条上限自动淘汰与「清空历史文档」管理。

    func clear() {
        for entry in entries {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(entry.snapshotFile))
        }
        entries.removeAll()
        save()
    }
}
