#!/bin/bash
# NotepadMac 构建脚本:SPM 编译 → 组装 .app bundle → ad-hoc 签名
# 用法: bash build.sh            (构建到 build/NotepadMac.app)
#       bash build.sh --install  (构建并拷贝到 /Applications,替换已有版本)
set -euo pipefail

cd "$(dirname "$0")"

CONFIG=release
APP_NAME="NotepadMac"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/$APP_NAME"
if [ ! -f "$BIN" ]; then
    echo "错误: 找不到编译产物 $BIN" >&2
    exit 1
fi

echo "==> 组装 $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN" "$CONTENTS/MacOS/$APP_NAME"
cp Scripts/Info.plist "$CONTENTS/Info.plist"

# 应用图标(iconutil 缺失时跳过,不影响功能)
if command -v iconutil >/dev/null 2>&1; then
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    mkdir -p "$ICONSET"
    echo "==> 生成图标"
    swift Scripts/make_icon.swift "$ICONSET"
    iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
else
    echo "警告: 未找到 iconutil,跳过图标"
fi

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP_DIR"

echo
echo "构建完成: $APP_DIR"
echo "  启动:    open $APP_DIR"
echo "  安装:    bash build.sh --install  (拷贝到 /Applications)"

if [ "${1:-}" = "--install" ]; then
    DEST="/Applications/$APP_NAME.app"
    echo "==> 安装到 $DEST"
    rm -rf "$DEST"
    cp -R "$APP_DIR" "$DEST"
    # 强制 LaunchServices 重新注册文件关联(右键"打开方式"立即可见)
    LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    if [ -x "$LSREGISTER" ]; then
        "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
    fi
    echo "安装完成,可从启动台/Launchpad 打开 NotepadMac"
fi
