// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotepadMac",
    platforms: [.macOS(.v13)],
    targets: [
        // 纯逻辑层(无 AppKit):编码 / 换行符 / 行索引 / 查找引擎 / 语法高亮规则
        // 独立成库以便在没有 XCTest 的 Command Line Tools 环境下做 standalone 单元测试
        .target(name: "NotepadCore", path: "Sources/NotepadCore"),
        .executableTarget(
            name: "NotepadMac",
            dependencies: ["NotepadCore"],
            path: "Sources/NotepadMac"
        ),
    ]
)
