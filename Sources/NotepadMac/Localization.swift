import Foundation

/// 本地化帮助:key 一律使用英文原文。
/// 英文系统直接显示 key(无需 en.lproj);中文翻译在 Resources/zh-Hans.lproj/Localizable.strings,
/// 由 build.sh 打包进 app bundle,系统按用户语言自动选择。
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// 带参数的本地化(文案里的数字/名字用 %d %@ 等占位)
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: args)
}
