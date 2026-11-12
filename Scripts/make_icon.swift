// 应用图标生成器:CoreGraphics 绘制 → iconset → iconutil 转 .icns
// 用法:swift Scripts/make_icon.swift <输出目录>
// 设计:macOS Big Sur 风格 —— 靛蓝→紫渐变 squircle 底,居中一张微倾白纸,
//       纸上是标题行 + 正文行(圆角条),末行跟一支橙色输入光标。

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

func makeContext(size: Int) -> CGContext? {
    CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

func drawIcon(size: Int) -> CGImage? {
    guard let ctx = makeContext(size: size) else { return nil }
    let s = CGFloat(size)
    let k = s / 1024.0 // 设计基准(以 1024 画布为准)

    // MARK: 背景 squircle(留出 Apple 规范的画布边距)

    let margin = 100 * k
    let inset = CGRect(x: margin, y: margin, width: s - margin * 2, height: s - margin * 2)
    let bgRadius = inset.width * 0.2237
    let bgPath = CGPath(roundedRect: inset, cornerWidth: bgRadius, cornerHeight: bgRadius, transform: nil)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()

    // 对角渐变:靛蓝 → 紫
    let bgColors = [
        CGColor(red: 0.27, green: 0.24, blue: 0.86, alpha: 1),
        CGColor(red: 0.55, green: 0.26, blue: 0.93, alpha: 1),
    ] as CFArray
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0, 1])!
    ctx.drawLinearGradient(bgGradient,
                           start: CGPoint(x: inset.minX, y: inset.maxY),
                           end: CGPoint(x: inset.maxX, y: inset.minY),
                           options: [])

    // 顶部径向高光,增加通透质感
    let sheen = CGGradient(colorsSpace: colorSpace,
                           colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.20),
                                    CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(sheen,
                           startCenter: CGPoint(x: inset.midX, y: inset.maxY),
                           startRadius: 0,
                           endCenter: CGPoint(x: inset.midX, y: inset.maxY),
                           endRadius: inset.width * 0.9,
                           options: [])

    // MARK: 白色纸张卡片(微倾 + 柔和投影)

    let cardW = 460 * k
    let cardH = 540 * k
    let cardCX = s / 2
    let cardCY = s / 2 + 6 * k
    let cardRadius = 34 * k
    let tilt: CGFloat = -.pi / 45 // -4°

    let cardRect = CGRect(x: -cardW / 2, y: -cardH / 2, width: cardW, height: cardH)
    let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)

    ctx.saveGState()
    ctx.translateBy(x: cardCX, y: cardCY)
    ctx.rotate(by: tilt)
    // 投影(CG y 轴向上,offset 用负值 = 向下投影)
    ctx.setShadow(offset: CGSize(width: 0, height: -16 * k),
                  blur: 32 * k,
                  color: CGColor(red: 0.04, green: 0.02, blue: 0.25, alpha: 0.45))
    ctx.addPath(cardPath)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // MARK: 纸上的文本行(同卡片坐标系,裁剪进纸内)

    ctx.saveGState()
    ctx.translateBy(x: cardCX, y: cardCY)
    ctx.rotate(by: tilt)
    ctx.addPath(cardPath)
    ctx.clip()

    let padX = cardW * 0.14
    let contentW = cardW - padX * 2
    let lineH = 36 * k
    let lineGap = 30 * k
    let leftX = -cardW / 2 + padX
    let topPad = 62 * k

    func drawTextLine(index: Int, widthRatio: CGFloat, color: CGColor) {
        let yTop = topPad + CGFloat(index) * (lineH + lineGap)
        let rect = CGRect(x: leftX, y: cardH / 2 - yTop - lineH,
                          width: contentW * widthRatio, height: lineH)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    let titleColor = CGColor(red: 0.20, green: 0.25, blue: 0.33, alpha: 1)   // 深墨(标题)
    let bodyColor = CGColor(red: 0.80, green: 0.84, blue: 0.90, alpha: 1)    // 浅灰蓝(正文)
    let ratios: [CGFloat] = [0.55, 0.92, 0.78, 0.88, 0.68, 0.42]
    for (i, ratio) in ratios.enumerated() {
        drawTextLine(index: i, widthRatio: ratio, color: i == 0 ? titleColor : bodyColor)
    }

    // 橙色输入光标:插在末行之后,点出"正在编辑"的场景
    let lastLineTop = topPad + CGFloat(ratios.count - 1) * (lineH + lineGap)
    let cursorW = 12 * k
    let cursorH = lineH + 8 * k
    let cursorX = leftX + contentW * ratios.last! + 16 * k
    let cursorRect = CGRect(x: cursorX, y: cardH / 2 - lastLineTop - 4 * k,
                            width: cursorW, height: cursorH)
    ctx.addPath(CGPath(roundedRect: cursorRect, cornerWidth: cursorW / 2, cornerHeight: cursorW / 2, transform: nil))
    ctx.setFillColor(CGColor(red: 0.97, green: 0.45, blue: 0.10, alpha: 1))
    ctx.fillPath()

    ctx.restoreGState()

    // MARK: squircle 边缘细描边(提升小尺寸下的轮廓清晰度)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.15))
    ctx.setLineWidth(3 * k)
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()
}

func main() {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        FileHandle.standardError.write("用法: swift make_icon.swift <输出iconset目录>\n".data(using: .utf8)!)
        exit(1)
    }
    let iconsetPath = args[1]
    let fm = FileManager.default
    try? fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

    // (文件名, 像素尺寸)
    let variants: [(String, Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    for (name, pixelSize) in variants {
        guard let image = drawIcon(size: pixelSize) else {
            FileHandle.standardError.write("绘制 \(name) 失败\n".data(using: .utf8)!)
            exit(1)
        }
        let url = URL(fileURLWithPath: iconsetPath).appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            FileHandle.standardError.write("创建 \(name) 输出失败\n".data(using: .utf8)!)
            exit(1)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            FileHandle.standardError.write("写入 \(name) 失败\n".data(using: .utf8)!)
            exit(1)
        }
    }
    print("iconset 已生成: \(iconsetPath)")
}

main()
