import Foundation

/// 自动保存调度:编辑去抖 + 周期兜底扫描。
/// 实际写盘由 MainWindowController.flushAll 完成,这里只负责"什么时候触发"。
final class AutoSaveController {

    /// 编辑后多少秒落盘
    static let debounceInterval: TimeInterval = 0.8
    /// 周期兜底扫描间隔
    static let sweepInterval: TimeInterval = 5.0

    var onFlushNeeded: (() -> Void)?

    private var debounceWork: DispatchWorkItem?
    private var sweepTimer: Timer?

    func start() {
        guard sweepTimer == nil else { return }
        let timer = Timer(timeInterval: Self.sweepInterval, repeats: true) { [weak self] _ in
            self?.onFlushNeeded?()
        }
        // .common 模式:用户连续打字/拖动界面时不被阻塞
        RunLoop.main.add(timer, forMode: .common)
        sweepTimer = timer
    }

    /// 内容变化时调用:重置去抖计时
    func scheduleDebouncedFlush() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onFlushNeeded?()
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    /// 立即触发一次(切标签/失焦时调用)
    func flushNow() {
        debounceWork?.cancel()
        debounceWork = nil
        onFlushNeeded?()
    }

    func stop() {
        debounceWork?.cancel()
        debounceWork = nil
        sweepTimer?.invalidate()
        sweepTimer = nil
    }
}
