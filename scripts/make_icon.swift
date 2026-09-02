// 生成 Agent IDEA 的应用图标。
//
// 用法：swift scripts/make_icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns && rm -rf Resources/AppIcon.iconset
// 产物 Resources/AppIcon.icns 提交进仓库，build_app.sh 只负责拷贝。
import AppKit
import Foundation

/// 深色圆角方块，一条靛蓝→紫→粉的渐变斜带，中间是「AI」。
func drawIcon(side: CGFloat) -> Data? {
    let pixels = Int(side)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    defer { NSGraphicsContext.restoreGraphicsState() }

    let inset = side * 0.09
    let rect = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = rect.width * 0.225
    let body = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // 底：IDEA 深色 UI 的底色
    NSColor(srgbRed: 0.118, green: 0.122, blue: 0.133, alpha: 1).setFill()
    body.fill()

    // 一条从左下到右上的渐变斜带，像 JetBrains 图标那种色块
    NSGraphicsContext.current?.saveGraphicsState()
    body.addClip()
    let band = NSBezierPath()
    band.move(to: NSPoint(x: rect.minX, y: rect.minY + rect.height * 0.15))
    band.line(to: NSPoint(x: rect.maxX, y: rect.minY + rect.height * 0.62))
    band.line(to: NSPoint(x: rect.maxX, y: rect.minY + rect.height * 0.98))
    band.line(to: NSPoint(x: rect.minX, y: rect.minY + rect.height * 0.51))
    band.close()
    NSGradient(colors: [
        NSColor(srgbRed: 0.208, green: 0.455, blue: 0.941, alpha: 1),  // #3574F0
        NSColor(srgbRed: 0.545, green: 0.302, blue: 0.867, alpha: 1),  // 紫
        NSColor(srgbRed: 0.929, green: 0.345, blue: 0.573, alpha: 1),  // 粉
    ])?.draw(in: band, angle: 20)
    NSGraphicsContext.current?.restoreGraphicsState()

    // 文字「AI」
    let text = "AI"
    let fontSize = rect.width * 0.36
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
        .foregroundColor: NSColor.white,
        .kern: -fontSize * 0.04,
    ]
    let size = (text as NSString).size(withAttributes: attributes)
    (text as NSString).draw(
        at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + rect.height * 0.02),
        withAttributes: attributes
    )

    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, side: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for variant in variants {
    guard let data = drawIcon(side: variant.side) else {
        FileHandle.standardError.write("画不出 \(variant.name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}
print("已生成 \(iconset.path)，接着跑 iconutil 转成 icns")
