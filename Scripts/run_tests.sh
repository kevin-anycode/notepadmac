#!/bin/bash
# 独立单元测试:无需 XCTest(适配仅有 Command Line Tools 的环境)
# 做法:先用 swiftc -emit-module 生成 NotepadCore 模块,再把 App 层被测文件与测试主体一起编译
# 用法: bash Scripts/run_tests.sh
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR=".build/testrunner"
MODULE_DIR=".build/testrunner/modules"
mkdir -p "$OUT_DIR" "$MODULE_DIR"

echo "==> 构建 NotepadCore 模块 + 静态库"
swiftc -O \
    -module-name NotepadCore \
    Sources/NotepadCore/*.swift \
    -emit-module \
    -emit-module-path "$MODULE_DIR/NotepadCore.swiftmodule" \
    -emit-library \
    -static \
    -o "$MODULE_DIR/libNotepadCore.a"

echo "==> 编译测试运行器"
swiftc -O \
    -I "$MODULE_DIR" \
    "$MODULE_DIR/libNotepadCore.a" \
    Sources/NotepadMac/Localization.swift \
    Sources/NotepadMac/Preferences.swift \
    Sources/NotepadMac/EditorTextView.swift \
    Sources/NotepadMac/LineNumberRulerView.swift \
    Sources/NotepadMac/EditorTab.swift \
    Sources/NotepadMac/SessionStore.swift \
    Sources/NotepadMac/TabBarView.swift \
    Sources/NotepadMac/HistoryStore.swift \
    TestsStandalone/main.swift \
    -o "$OUT_DIR/notepadmac-test"

echo "==> 运行测试"
"$OUT_DIR/notepadmac-test"
