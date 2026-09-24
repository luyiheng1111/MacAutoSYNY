// SYNY 应用图标生成器（纯 Swift / CoreGraphics 版）
//
// 等价替换原来的 tools/make_icon.py：同样的圆角渐变底板 + 白色 WiFi 信号弧，
// 但不再需要 Python 与 iconutil 之外的任何依赖。
//
// 用法：icongen <输出目录>
//   产物：<输出目录>/icon.icns、<输出目录>/icon_preview.png、<输出目录>/SYNY.iconset/
//
// 实现要点与 Python 版保持一致：
//   - 4 倍超采样后降采样，保证小尺寸（16pt）边缘依然干净；
//   - 底板为圆角矩形，渐变从左上（蓝 #3B82F6）到右下（青 #0BB0A0）；
//   - 信号图形 = 底部圆点 + 三条向上张开的弧（±48° 窗口）。

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// MARK: - 常量（与 make_icon.py 对齐）

let supersample = 4                      // 超采样倍数，用于抗锯齿
let topColor = (r: 0x3B / 255.0, g: 0x82 / 255.0, b: 0xF6 / 255.0)      // 蓝
let bottomColor = (r: 0x0B / 255.0, g: 0xB0 / 255.0, b: 0xA0 / 255.0)   // 青

/// 圆角矩形的内缩比例与圆角半径比例
let bodyInsetRatio = 0.045
let cornerRadiusRatio = 0.225

/// 信号图形：圆心位置、圆点半径、三条弧（半径, 线宽）、张角半宽
/// （圆心位置沿用 Python 版的「自顶部起算」比例，绘制时再换算到 CoreGraphics 坐标系）
let glyphCenterYRatio = 0.735
let dotRadiusRatio = 0.062
let arcs: [(radius: Double, width: Double)] = [
    (0.145, 0.062),
    (0.255, 0.062),
    (0.365, 0.058),
]
let arcHalfSpanDegrees = 48.0

// MARK: - 绘制

/// 生成指定边长的图标位图。
func renderIcon(size: Int) -> CGImage? {
    let scale = supersample
    let big = size * scale
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    guard let context = CGContext(data: nil,
                                  width: big, height: big,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }

    let n = CGFloat(big)
    // CoreGraphics 原点在左下角；`glyphCenterYRatio` 在 Python 版里是「自顶部起算」，
    // 这里换算成自底部起算的 y。
    let center = CGPoint(x: n * 0.5, y: n * (1.0 - glyphCenterYRatio))

    // 1) 圆角矩形底板 + 对角渐变
    let inset = n * CGFloat(bodyInsetRatio)
    let body = CGRect(x: inset, y: inset, width: n - inset * 2, height: n - inset * 2)
    let cornerRadius = n * CGFloat(cornerRadiusRatio)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: cornerRadius,
                          cornerHeight: cornerRadius, transform: nil)

    context.saveGState()
    context.addPath(bodyPath)
    context.clip()

    let gradient = CGGradient(colorsSpace: colorSpace,
                              colors: [
                                  CGColor(red: topColor.r, green: topColor.g,
                                          blue: topColor.b, alpha: 1),
                                  CGColor(red: bottomColor.r, green: bottomColor.g,
                                          blue: bottomColor.b, alpha: 1),
                              ] as CFArray,
                              locations: [0, 1])
    if let gradient {
        // 左上 → 右下
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: n),
                                   end: CGPoint(x: n, y: 0),
                                   options: [])
    }
    context.restoreGState()

    // 2) 白色信号图形，同样裁剪在底板内
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.setLineCap(.butt)

    let startAngle = CGFloat((90.0 - arcHalfSpanDegrees) * Double.pi / 180.0)
    let endAngle = CGFloat((90.0 + arcHalfSpanDegrees) * Double.pi / 180.0)
    for arc in arcs {
        context.setLineWidth(n * CGFloat(arc.width))
        context.addArc(center: center, radius: n * CGFloat(arc.radius),
                       startAngle: startAngle, endAngle: endAngle, clockwise: false)
        context.strokePath()
    }
    context.fillEllipse(in: CGRect(x: center.x - n * CGFloat(dotRadiusRatio),
                                   y: center.y - n * CGFloat(dotRadiusRatio),
                                   width: n * CGFloat(dotRadiusRatio) * 2,
                                   height: n * CGFloat(dotRadiusRatio) * 2))
    context.restoreGState()

    guard let bigImage = context.makeImage() else { return nil }

    // 3) 降采样到目标尺寸
    guard let output = CGContext(data: nil,
                                 width: size, height: size,
                                 bitsPerComponent: 8,
                                 bytesPerRow: 0,
                                 space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    output.interpolationQuality = .high
    output.draw(bigImage, in: CGRect(x: 0, y: 0, width: size, height: size))
    return output.makeImage()
}

// MARK: - 输出

func writePNG(_ image: CGImage, to path: String, dpi: Int? = nil) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
    // 写入 DPI 元数据：Finder 用「像素 / (DPI/72)」换算图片的逻辑尺寸，
    // 1200x840 @144dpi 即 600x420 点，与窗口内容区一一对应。
    var properties: [CFString: Any] = [:]
    if let dpi {
        properties[kCGImagePropertyDPIWidth] = dpi
        properties[kCGImagePropertyDPIHeight] = dpi
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    return CGImageDestinationFinalize(destination)
}

func runCommand(_ path: String, _ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

// MARK: - DMG 安装盘背景图
//
// Finder 把这张图铺在窗口内容区最底层（左上角对齐），图标压在上面。
// 内容区高度 = 窗口外框高度 − 标题栏/状态栏（约 44pt）。
// 为了不依赖某个具体 macOS 版本的装饰高度，图比设计区多留 dmgBottomPad
// 的底部余量：装饰高一点就多露一点渐变，不会裁掉正文。
//
// 图标落点是 .DS_Store 里的绝对坐标（原点在内容区左上），
// 与下面这几个 center 一一对应，改动必须同步 packaging/dmg_layout.DS_Store。

let dmgWidth = 600
let dmgDesignHeight = 420        // 设计区高度（= 窗口内容区高度）
let dmgBottomPad = 56            // 底部余量：吸收窗口装饰高度差异
let dmgHeight = dmgDesignHeight + dmgBottomPad
// 图标行（CoreGraphics 坐标，原点在左下，y 自设计区底部起算）
// 左「安装说明」x=95 / 中「SYNY」x=262 / 右「应用程序」x=497
let appSlotCenter = CGPoint(x: 262, y: 220)
let targetSlotCenter = CGPoint(x: 497, y: 220)

func drawText(_ text: String, in context: CGContext, centeredAtX centerX: CGFloat,
              baselineY: CGFloat, font: CTFont, color: CGColor) {
    // 只用 CoreText 原生属性键，避免为了 .font / .foregroundColor 这两个写法
    // 把 AppKit 也拖进来
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: attributes))
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    context.textPosition = CGPoint(x: centerX - width / 2, y: baselineY)
    CTLineDraw(line, context)
}

/// 以 `scale` 倍超采样渲染背景图（scale=2 时输出 1200x952，配合 144 DPI
/// 元数据，Finder 按 600x476 点铺设，Retina 屏上不糊）。
func renderDmgBackground(scale: CGFloat = 1) -> CGImage? {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil,
                                  width: Int(CGFloat(dmgWidth) * scale),
                                  height: Int(CGFloat(dmgHeight) * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return nil
    }
    // 之后的绘制全部用「点」坐标系，缩放交给上下文
    context.scaleBy(x: scale, y: scale)
    let width = CGFloat(dmgWidth)
    let canvasHeight = CGFloat(dmgHeight)

    // 底色：自上而下的极浅灰渐变，铺满整张画布（含底部余量），
    // 和大多数 macOS 安装盘的观感一致
    let background = CGGradient(colorsSpace: colorSpace, colors: [
        CGColor(red: 0.988, green: 0.992, blue: 0.996, alpha: 1),
        CGColor(red: 0.929, green: 0.945, blue: 0.965, alpha: 1),
    ] as CFArray, locations: [0, 1])
    if let background {
        context.drawLinearGradient(background,
                                   start: CGPoint(x: 0, y: canvasHeight),
                                   end: CGPoint(x: 0, y: 0),
                                   options: [])
    }

    // 把坐标系平移到「设计区」：设计区占画布顶部，底部 dmgBottomPad 只留渐变
    context.translateBy(x: 0, y: CGFloat(dmgBottomPad))
    let height = CGFloat(dmgDesignHeight)

    let titleFont = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 21, nil)
    let bodyFont = CTFontCreateWithName("PingFangSC-Regular" as CFString, 13, nil)
    let hintFont = CTFontCreateWithName("PingFangSC-Regular" as CFString, 12.5, nil)
    let ink = CGColor(red: 0.13, green: 0.16, blue: 0.20, alpha: 1)
    let muted = CGColor(red: 0.35, green: 0.40, blue: 0.46, alpha: 1)

    // 标题区
    drawText("安装 SYNY 校园网自动认证", in: context, centeredAtX: width / 2,
             baselineY: height - 48, font: titleFont, color: ink)
    drawText("把左边的 SYNY 拖到右边的「应用程序」文件夹", in: context,
             centeredAtX: width / 2, baselineY: height - 74, font: bodyFont, color: muted)

    // 「应用程序」落点：画一个虚线目标框（真正的文件夹图标会被 Finder 覆盖在正中）
    context.saveGState()
    context.setStrokeColor(CGColor(red: 0.42, green: 0.51, blue: 0.62, alpha: 0.55))
    context.setLineWidth(2)
    context.setLineDash(phase: 0, lengths: [7, 6])
    let slotSize: CGFloat = 152
    let slot = CGRect(x: targetSlotCenter.x - slotSize / 2,
                      y: targetSlotCenter.y - slotSize / 2,
                      width: slotSize, height: slotSize)
    context.addPath(CGPath(roundedRect: slot, cornerWidth: 18, cornerHeight: 18,
                          transform: nil))
    context.strokePath()
    context.restoreGState()

    // 中间的箭头
    context.saveGState()
    context.setStrokeColor(CGColor(red: 0.24, green: 0.51, blue: 0.96, alpha: 0.85))
    context.setFillColor(CGColor(red: 0.24, green: 0.51, blue: 0.96, alpha: 0.85))
    context.setLineWidth(4)
    context.setLineCap(.round)
    let arrowY = appSlotCenter.y
    let tailX = appSlotCenter.x + 74
    let tipX = targetSlotCenter.x - 99        // 箭头尖端（右端，指向「应用程序」）
    context.move(to: CGPoint(x: tailX, y: arrowY))
    context.addLine(to: CGPoint(x: tipX, y: arrowY))
    context.strokePath()
    // 箭头三角：尖端在 tipX（朝右），底边在 tipX-16
    context.move(to: CGPoint(x: tipX - 16, y: arrowY + 11))
    context.addLine(to: CGPoint(x: tipX, y: arrowY))
    context.addLine(to: CGPoint(x: tipX - 16, y: arrowY - 11))
    context.closePath()
    context.fillPath()
    context.restoreGState()

    // 底部提示卡：第一次安装最容易卡住的地方（Gatekeeper 拦截）
    let card = CGRect(x: 40, y: 18, width: width - 80, height: 92)
    context.saveGState()
    context.setFillColor(CGColor(red: 1, green: 0.98, blue: 0.93, alpha: 1))
    context.addPath(CGPath(roundedRect: card, cornerWidth: 12, cornerHeight: 12,
                          transform: nil))
    context.fillPath()
    context.setStrokeColor(CGColor(red: 0.92, green: 0.79, blue: 0.51, alpha: 1))
    context.setLineWidth(1)
    context.addPath(CGPath(roundedRect: card, cornerWidth: 12, cornerHeight: 12,
                          transform: nil))
    context.strokePath()
    context.restoreGState()

    let warningInk = CGColor(red: 0.55, green: 0.35, blue: 0.03, alpha: 1)
    drawText("首次打开若提示「无法验证开发者」，属于 macOS 的正常安全提示。",
             in: context, centeredAtX: width / 2, baselineY: 80,
             font: hintFont, color: warningInk)
    drawText("点「完成」→ 系统设置 → 隐私与安全性 → 点「仍要打开」即可。",
             in: context, centeredAtX: width / 2, baselineY: 60,
             font: hintFont, color: warningInk)
    drawText("详细步骤见同目录下的「安装说明.txt」。",
             in: context, centeredAtX: width / 2, baselineY: 40,
             font: hintFont, color: warningInk)

    return context.makeImage()
}

// MARK: - 主流程

let fileManager = FileManager.default
var arguments = Array(CommandLine.arguments.dropFirst())

// 子命令：只生成 DMG 安装盘背景图
//   icongen --dmg-background <输出路径> [--scale 2] [--dpi 144]
if arguments.first == "--dmg-background" {
    let output = arguments.count > 1 ? arguments[1] : "dmg_background.png"
    var scale: CGFloat = 1
    var dpi: Int? = nil
    if let i = arguments.firstIndex(of: "--scale"), i + 1 < arguments.count,
       let value = Double(arguments[i + 1]) { scale = CGFloat(value) }
    if let i = arguments.firstIndex(of: "--dpi"), i + 1 < arguments.count,
       let value = Int(arguments[i + 1]) { dpi = value }
    guard let image = renderDmgBackground(scale: scale), writePNG(image, to: output, dpi: dpi) else {
        FileHandle.standardError.write(Data("DMG 背景图生成失败\n".utf8))
        exit(1)
    }
    print("已生成 \(output)")
    exit(0)
}

// 子命令：改写 .DS_Store 里记录的 Finder 窗口尺寸
//   icongen --patch-dmg-layout <.DS_Store 路径> <宽>x<高>
//
// 背景：Finder 的 AppleScript「set bounds」在不同 macOS 版本上行为不一致
// （实测会把 600x420 存成 920x464），而 .DS_Store 里 bwsp 记录的
// WindowBounds 才是真正决定窗口大小的值。这里直接原地改写该字段：
// 新旧数字位数必须一致，因此长度不变，不会破坏 DS_Store 的 B-tree 结构。
if arguments.first == "--patch-dmg-layout" {
    guard arguments.count >= 3 else {
        FileHandle.standardError.write(Data("用法：icongen --patch-dmg-layout <.DS_Store> <宽>x<高>\n".utf8))
        exit(2)
    }
    let path = arguments[1]
    let parts = arguments[2].split(separator: "x")
    guard parts.count == 2, let newWidth = Int(parts[0]), let newHeight = Int(parts[1]) else {
        FileHandle.standardError.write(Data("尺寸格式应为 600x464\n".utf8))
        exit(2)
    }
    guard let raw = fileManager.contents(atPath: path),
          var text = String(data: raw, encoding: .isoLatin1) else {
        FileHandle.standardError.write(Data("读不到 .DS_Store：\(path)\n".utf8))
        exit(1)
    }
    let pattern = #"\{\{\d+, \d+\}, \{\d+, \d+\}\}"#
    let regex = try! NSRegularExpression(pattern: pattern)
    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    var patched = 0
    for match in matches.reversed() {
        guard let range = Range(match.range, in: text) else { continue }
        let original = String(text[range])
        let numbers = original.split(whereSeparator: { !$0.isNumber }).map(String.init)
        guard numbers.count == 4, let x = Int(numbers[0]), let y = Int(numbers[1]) else { continue }
        let replacement = "{{\(x), \(y)}, {\(newWidth), \(newHeight)}}"
        guard replacement.utf8.count == original.utf8.count else {
            FileHandle.standardError.write(Data(
                "尺寸位数不一致（\(original) → \(replacement)），无法原地替换\n".utf8))
            exit(3)
        }
        text.replaceSubrange(range, with: replacement)
        patched += 1
    }
    guard patched > 0 else {
        FileHandle.standardError.write(Data("未找到 WindowBounds 字段\n".utf8))
        exit(4)
    }
    guard let output = text.data(using: .isoLatin1) else { exit(1) }
    try! output.write(to: URL(fileURLWithPath: path))
    print("已将窗口尺寸改写为 \(newWidth)x\(newHeight)（\(patched) 处）")
    exit(0)
}

let outputDirectory = arguments.first ?? (fileManager.currentDirectoryPath + "/build")
let iconsetDirectory = outputDirectory + "/SYNY.iconset"
try? fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
try? fileManager.removeItem(atPath: iconsetDirectory)
try? fileManager.createDirectory(atPath: iconsetDirectory, withIntermediateDirectories: true)

let iconsetEntries: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

var cache: [Int: CGImage] = [:]
var failed = false
for entry in iconsetEntries {
    if cache[entry.size] == nil {
        cache[entry.size] = renderIcon(size: entry.size)
    }
    guard let image = cache[entry.size],
          writePNG(image, to: iconsetDirectory + "/" + entry.name) else {
        FileHandle.standardError.write(Data("图标生成失败：\(entry.name)\n".utf8))
        failed = true
        break
    }
}

if failed { exit(1) }

if let preview = cache[512] {
    _ = writePNG(preview, to: outputDirectory + "/icon_preview.png")
    print("已生成 \(outputDirectory)/icon_preview.png")
}

let iconutil = "/usr/bin/iconutil"
if fileManager.isExecutableFile(atPath: iconutil) {
    if runCommand(iconutil, ["-c", "icns", iconsetDirectory,
                             "-o", outputDirectory + "/icon.icns"]) {
        print("已生成 \(outputDirectory)/icon.icns")
    } else {
        print("iconutil 生成 .icns 失败，已跳过")
    }
} else {
    print("未找到 iconutil，跳过 .icns 生成")
}
