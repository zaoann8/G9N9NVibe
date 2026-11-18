import AppKit
import CoreGraphics
import Foundation

// G9N9N-Vibe 官方图标生成器：博朗 Dieter Rams 瓷白硬件面板风格
// 严格遵循 Apple macOS HIG 图标网格（1024px 透明画布 + 824px 居中圆角主体 + 185.4px 圆角）
// 原生生成标准多分辨率 Apple .icns 与 1024px 透明底 AppIcon.png，零外部工具依赖
// 用法：generate-app-icon <AppIcon.icns输出路径> <AppIcon.png输出路径>

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("用法: generate-app-icon <AppIcon.icns路径> <AppIcon.png路径>\n", stderr)
    exit(1)
}

let icnsPath = args[1]
let masterPngPath = args[2]

func cgColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(srgbRed: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a)
}

func squirclePath(in r: CGRect, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: r.minX + radius, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + radius), radius: radius)
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
    p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - radius, y: r.maxY), radius: radius)
    p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - radius), radius: radius)
    p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
    p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + radius, y: r.minY), radius: radius)
    p.closeSubpath()
    return p
}

func drawLinearGradient(
    _ ctx: CGContext,
    colors: [CGColor],
    locations: [CGFloat],
    start: CGPoint,
    end: CGPoint
) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let grad = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(grad, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func drawRadialGradient(
    _ ctx: CGContext,
    colors: [CGColor],
    locations: [CGFloat],
    center: CGPoint,
    startRadius: CGFloat,
    endRadius: CGFloat
) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let grad = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    ctx.drawRadialGradient(
        grad,
        startCenter: center,
        startRadius: startRadius,
        endCenter: center,
        endRadius: endRadius,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
}

func drawText(
    text: String,
    font: NSFont,
    color: NSColor,
    rect: CGRect,
    alignment: NSTextAlignment = .left,
    kern: CGFloat = 0
) {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: style,
        .kern: kern
    ]
    NSAttributedString(string: text, attributes: attrs).draw(in: rect)
}

/// 以 1024 逻辑坐标系绘制博朗瓷白硬件面板透明底图标，自动按像素尺寸缩放并对超小尺寸优化锐度
func renderBraunIcon(pixelSize: Int, pointSize: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let scale = CGFloat(pixelSize) / 1024.0
    ctx.translateBy(x: 0, y: CGFloat(pixelSize))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

    // 全透明画布，严守 Apple macOS 图标 824x824 主体安全区域
    ctx.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let cornerRadius: CGFloat = 185.4
    let iconPath = squirclePath(in: iconRect, radius: cornerRadius)

    // macOS 原生规范底部轻柔投影（保证完全落在 1024 画布内，不裁边）
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 26, color: cgColor(20, 17, 14, 0.28))
    ctx.addPath(iconPath)
    ctx.setFillColor(cgColor(238, 233, 224, 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // 裁剪机身内部进行细节绘制
    ctx.saveGState()
    ctx.addPath(iconPath)
    ctx.clip()

    // 暖米瓷白磨砂机身底色
    drawLinearGradient(
        ctx,
        colors: [cgColor(251, 248, 242), cgColor(242, 237, 228), cgColor(231, 225, 214)],
        locations: [0.0, 0.56, 1.0],
        start: CGPoint(x: iconRect.minX, y: iconRect.minY),
        end: CGPoint(x: iconRect.maxX, y: iconRect.maxY)
    )

    // 顶部柔和陶瓷环境光
    drawRadialGradient(
        ctx,
        colors: [cgColor(255, 255, 255, 0.80), cgColor(255, 255, 255, 0.0)],
        locations: [0, 1],
        center: CGPoint(x: iconRect.midX, y: iconRect.minY + 34),
        startRadius: 12,
        endRadius: 560
    )

    // 顶部与操作区的精密切槽分隔线
    let dividerY = iconRect.minY + 260
    ctx.setFillColor(cgColor(28, 25, 22, 0.12))
    ctx.fill(CGRect(x: iconRect.minX + 74, y: dividerY, width: iconRect.width - 148, height: 3.0))
    ctx.setFillColor(cgColor(255, 255, 255, 0.88))
    ctx.fill(CGRect(x: iconRect.minX + 74, y: dividerY + 3.0, width: iconRect.width - 148, height: 2.5))

    // 顶部左侧：深暖炭工业型号刻字 G9N9N
    let modelFont = NSFont.systemFont(ofSize: 108, weight: .heavy)
    drawText(
        text: "G9N9N",
        font: modelFont,
        color: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9),
        rect: CGRect(x: iconRect.minX + 78, y: iconRect.minY + 101, width: 560, height: 136),
        alignment: .left,
        kern: 6.5
    )
    drawText(
        text: "G9N9N",
        font: modelFont,
        color: NSColor(srgbRed: 0.12, green: 0.11, blue: 0.10, alpha: 1.0),
        rect: CGRect(x: iconRect.minX + 78, y: iconRect.minY + 97, width: 560, height: 136),
        alignment: .left,
        kern: 6.5
    )

    // 顶部右侧：森林翠绿硬件状态指示灯
    let ledCenter = CGPoint(x: iconRect.maxX - 110, y: iconRect.minY + 160)
    ctx.setFillColor(cgColor(196, 189, 176, 1))
    ctx.fillEllipse(in: CGRect(x: ledCenter.x - 24, y: ledCenter.y - 24, width: 48, height: 48))
    drawRadialGradient(
        ctx,
        colors: [cgColor(30, 188, 118, 0.68), cgColor(21, 132, 82, 0.0)],
        locations: [0, 1],
        center: ledCenter,
        startRadius: 10,
        endRadius: 42
    )
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: ledCenter.x - 17, y: ledCenter.y - 17, width: 34, height: 34))
    ctx.clip()
    drawRadialGradient(
        ctx,
        colors: [cgColor(138, 250, 195), cgColor(26, 168, 104), cgColor(15, 108, 66)],
        locations: [0, 0.55, 1],
        center: CGPoint(x: ledCenter.x - 5, y: ledCenter.y - 5),
        startRadius: 1,
        endRadius: 18
    )
    ctx.restoreGState()

    // 下半区左侧：标志性朱砂橙物理凹面语音触发键
    let btnCenter = CGPoint(x: iconRect.minX + 244, y: iconRect.minY + 522)
    let btnOuterR: CGFloat = 166
    let btnR: CGFloat = 146

    // 按键精密机加工沉台
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: btnCenter.x - btnOuterR, y: btnCenter.y - btnOuterR, width: btnOuterR * 2, height: btnOuterR * 2))
    ctx.clip()
    drawLinearGradient(
        ctx,
        colors: [cgColor(194, 187, 175), cgColor(238, 233, 224), cgColor(255, 253, 249)],
        locations: [0, 0.5, 1],
        start: CGPoint(x: btnCenter.x, y: btnCenter.y - btnOuterR),
        end: CGPoint(x: btnCenter.x, y: btnCenter.y + btnOuterR)
    )
    ctx.restoreGState()

    // 朱砂橙按键柔和投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: cgColor(175, 42, 12, 0.34))
    ctx.setFillColor(cgColor(230, 70, 30))
    ctx.fillEllipse(in: CGRect(x: btnCenter.x - btnR, y: btnCenter.y - btnR, width: btnR * 2, height: btnR * 2))
    ctx.restoreGState()

    // 按键本体立体光照与内凹触感
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: btnCenter.x - btnR, y: btnCenter.y - btnR, width: btnR * 2, height: btnR * 2))
    ctx.clip()
    drawLinearGradient(
        ctx,
        colors: [cgColor(248, 96, 50), cgColor(230, 70, 30), cgColor(192, 45, 14)],
        locations: [0, 0.52, 1],
        start: CGPoint(x: btnCenter.x - 40, y: btnCenter.y - btnR),
        end: CGPoint(x: btnCenter.x + 40, y: btnCenter.y + btnR)
    )
    let dishR: CGFloat = 108
    ctx.addEllipse(in: CGRect(x: btnCenter.x - dishR, y: btnCenter.y - dishR, width: dishR * 2, height: dishR * 2))
    ctx.clip()
    drawLinearGradient(
        ctx,
        colors: [cgColor(168, 36, 10, 0.24), cgColor(255, 168, 126, 0.22)],
        locations: [0, 1],
        start: CGPoint(x: btnCenter.x, y: btnCenter.y - dishR),
        end: CGPoint(x: btnCenter.x, y: btnCenter.y + dishR)
    )
    ctx.restoreGState()

    // 按键中心：暖白发光声控四芒星
    ctx.saveGState()
    let star = CGMutablePath()
    let sOut: CGFloat = 50
    let sIn: CGFloat = 13
    star.move(to: CGPoint(x: btnCenter.x, y: btnCenter.y - sOut))
    star.addQuadCurve(to: CGPoint(x: btnCenter.x + sOut, y: btnCenter.y), control: CGPoint(x: btnCenter.x + sIn, y: btnCenter.y - sIn))
    star.addQuadCurve(to: CGPoint(x: btnCenter.x, y: btnCenter.y + sOut), control: CGPoint(x: btnCenter.x + sIn, y: btnCenter.y + sIn))
    star.addQuadCurve(to: CGPoint(x: btnCenter.x - sOut, y: btnCenter.y), control: CGPoint(x: btnCenter.x - sIn, y: btnCenter.y + sIn))
    star.addQuadCurve(to: CGPoint(x: btnCenter.x, y: btnCenter.y - sOut), control: CGPoint(x: btnCenter.x - sIn, y: btnCenter.y - sIn))
    star.closeSubpath()
    ctx.setShadow(offset: .zero, blur: 16, color: cgColor(255, 255, 255, 0.72))
    ctx.addPath(star)
    ctx.setFillColor(cgColor(255, 252, 246, 0.98))
    ctx.fillPath()
    ctx.restoreGState()

    // 下半区右侧：博朗经典圆形精密麦克风微孔阵列（小图标自动减少行列保证清晰锐利）
    let grilleCenter = CGPoint(x: iconRect.maxX - 222, y: iconRect.minY + 522)
    let isTiny = pixelSize <= 32
    let halfGrid = isTiny ? 2 : 4
    let spacing: CGFloat = isTiny ? 62 : 37.5
    let maxDist: CGFloat = isTiny ? 136 : 144
    for row in -halfGrid...halfGrid {
        for col in -halfGrid...halfGrid {
            let dx = CGFloat(col) * spacing
            let dy = CGFloat(row) * spacing
            let dist = hypot(dx, dy)
            if dist <= maxDist {
                let holeR: CGFloat = isTiny ? 17.5 : (dist < 76 ? 10.6 : (dist < 118 ? 9.2 : 7.6))
                let cx = grilleCenter.x + dx
                let cy = grilleCenter.y + dy
                ctx.setFillColor(cgColor(255, 255, 255, 0.9))
                ctx.fillEllipse(in: CGRect(x: cx - holeR, y: cy - holeR + 2.2, width: holeR * 2, height: holeR * 2))
                ctx.saveGState()
                ctx.addEllipse(in: CGRect(x: cx - holeR, y: cy - holeR, width: holeR * 2, height: holeR * 2))
                ctx.clip()
                drawLinearGradient(
                    ctx,
                    colors: [cgColor(22, 20, 18), cgColor(62, 58, 52)],
                    locations: [0, 1],
                    start: CGPoint(x: cx, y: cy - holeR),
                    end: CGPoint(x: cx, y: cy + holeR)
                )
                ctx.restoreGState()
            }
        }
    }

    // 底部工业铭文（仅在 128px 及以上尺寸绘制，避免小图标出现模糊杂点）
    if pixelSize >= 128 {
        let subFont = NSFont.monospacedSystemFont(ofSize: 24, weight: .bold)
        drawText(
            text: "VIBE AUDIO CONTROLLER",
            font: subFont,
            color: NSColor(srgbRed: 0.42, green: 0.39, blue: 0.35, alpha: 0.84),
            rect: CGRect(x: iconRect.minX, y: iconRect.maxY - 82, width: iconRect.width, height: 38),
            alignment: .center,
            kern: 6.0
        )
    }

    // 外缘双层质感描边（浅色壁纸/暗色壁纸均清晰勾勒轮廓）
    ctx.addPath(iconPath)
    ctx.setStrokeColor(cgColor(255, 255, 255, 0.85))
    ctx.setLineWidth(6)
    ctx.strokePath()
    ctx.restoreGState()

    // 极细外轮廓压边（确保在纯白 Finder 窗口中也立体可见）
    ctx.saveGState()
    ctx.addPath(iconPath)
    ctx.setStrokeColor(cgColor(28, 24, 20, 0.14))
    ctx.setLineWidth(2.5)
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    // 设置正确逻辑尺寸（1x 为 72 DPI，@2x 为 144 DPI，严格满足 iconutil 校验）
    rep.size = NSSize(width: pointSize, height: pointSize)
    return rep.representation(using: .png, properties: [:])!
}

/// 追加大端 32 位无符号整数到二进制缓冲
func appendBigEndianUInt32(_ data: inout Data, _ value: UInt32) {
    var be = value.bigEndian
    withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
}

// 渲染各标准尺寸 PNG 缓存（避免重复渲染相同像素尺寸）
var pngCache: [Int: Data] = [:]
for px in [16, 32, 64, 128, 256, 512, 1024] {
    pngCache[px] = renderBraunIcon(pixelSize: px, pointSize: px)
}

// 标准 macOS .icns 全档 PNG Chunk 映射（兼容 macOS 10.7 ~ macOS 15+ Retina 与普通屏）
let icnsChunks: [(String, Int)] = [
    ("icp4", 16),   // 16x16 @1x
    ("ic11", 32),   // 16x16 @2x
    ("icp5", 32),   // 32x32 @1x
    ("ic12", 64),   // 32x32 @2x
    ("icp6", 64),   // 64x64 @1x
    ("ic07", 128),  // 128x128 @1x
    ("ic13", 256),  // 128x128 @2x
    ("ic08", 256),  // 256x256 @1x
    ("ic14", 512),  // 256x256 @2x
    ("ic09", 512),  // 512x512 @1x
    ("ic10", 1024)  // 512x512 @2x (1024x1024)
]

var body = Data()
for (fourCC, px) in icnsChunks {
    guard let png = pngCache[px] else { continue }
    let chunkLen = UInt32(8 + png.count)
    body.append(fourCC.data(using: .ascii)!)
    appendBigEndianUInt32(&body, chunkLen)
    body.append(png)
}

var icnsData = Data()
icnsData.append("icns".data(using: .ascii)!)
appendBigEndianUInt32(&icnsData, UInt32(8 + body.count))
icnsData.append(body)

let fm = FileManager.default
try! fm.createDirectory(at: URL(fileURLWithPath: icnsPath).deletingLastPathComponent(), withIntermediateDirectories: true)
try! fm.createDirectory(at: URL(fileURLWithPath: masterPngPath).deletingLastPathComponent(), withIntermediateDirectories: true)
try! icnsData.write(to: URL(fileURLWithPath: icnsPath))
try! pngCache[1024]!.write(to: URL(fileURLWithPath: masterPngPath))

// 使用 AppKit NSImage 原地自验生成的 .icns 可正常解码且包含多分辨率图层
guard let verifyImg = NSImage(contentsOfFile: icnsPath), verifyImg.representations.count >= 6 else {
    fputs("❌ .icns 自验失败\n", stderr)
    exit(2)
}

print("✅ 已生成标准多分辨率 AppIcon.icns (\(icnsData.count) bytes, \(verifyImg.representations.count) 个图层) 与 AppIcon.png")
