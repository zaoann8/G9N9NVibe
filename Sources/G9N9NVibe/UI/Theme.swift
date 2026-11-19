import AppKit
import SwiftUI

/// G9NVibe 方案 A 精工字体系统：英文/数字使用 Avenir Next，中文强制级联「冬青黑体 Hiragino Sans GB」
/// 通过 CoreText NSFontDescriptor.cascadeList 精确合成并缓存，0 KB 额外字体体积
enum VibeFont {
    private static let lock = NSLock()
    private static var cache: [String: Font] = [:]

    private static func make(latinName: String, cjkName: String, size: CGFloat) -> Font {
        let key = "\(latinName)|\(cjkName)|\(Int((size * 10).rounded()))"
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let cjkDesc = NSFontDescriptor(name: cjkName, size: size)
        let primaryDesc = NSFontDescriptor(name: latinName, size: size).addingAttributes([
            .cascadeList: [cjkDesc]
        ])
        let font: Font
        if let nsFont = NSFont(descriptor: primaryDesc, size: size) {
            font = Font(nsFont)
        } else {
            font = .system(size: size)
        }
        lock.lock()
        cache[key] = font
        lock.unlock()
        return font
    }

    /// 品牌标题与弹窗大标题（AvenirNext-DemiBold + 冬青黑体 W6）
    static func brand(_ size: CGFloat = 15) -> Font {
        make(latinName: "AvenirNext-DemiBold", cjkName: "HiraginoSansGB-W6", size: size)
    }

    /// 卡片主标题（温润饱满不厚重）
    static func title(_ size: CGFloat = 14) -> Font {
        make(latinName: "AvenirNext-DemiBold", cjkName: "HiraginoSansGB-W6", size: size)
    }

    /// 按钮与关键标签
    static func label(_ size: CGFloat = 12, weight: Font.Weight = .medium) -> Font {
        switch weight {
        case .bold, .heavy, .black:
            return make(latinName: "AvenirNext-DemiBold", cjkName: "HiraginoSansGB-W6", size: size)
        case .semibold:
            return make(latinName: "AvenirNext-DemiBold", cjkName: "HiraginoSansGB-W6", size: size)
        case .regular, .light, .thin, .ultraLight:
            return make(latinName: "AvenirNext-Regular", cjkName: "HiraginoSansGB-W3", size: size)
        default:
            return make(latinName: "AvenirNext-Medium", cjkName: "HiraginoSansGB-W3", size: size)
        }
    }

    /// 辅助说明正文（AvenirNext-Regular + 冬青黑体 W3）
    static func caption(_ size: CGFloat = 11.5) -> Font {
        make(latinName: "AvenirNext-Regular", cjkName: "HiraginoSansGB-W3", size: size)
    }

    /// 精密数值与快捷键徽标（SF Mono 等宽防跳动 + 冬青黑体 W3 级联）
    static func mono(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> Font {
        let weightTag = (weight == .bold || weight == .semibold) ? "semi" : "med"
        let key = "mono|\(weightTag)|\(Int((size * 10).rounded()))"
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let nsWeight: NSFont.Weight = (weight == .bold || weight == .semibold) ? .semibold : .medium
        let base = NSFont.monospacedSystemFont(ofSize: size, weight: nsWeight)
        let cjkDesc = NSFontDescriptor(name: "HiraginoSansGB-W3", size: size)
        let desc = base.fontDescriptor.addingAttributes([.cascadeList: [cjkDesc]])
        let font = NSFont(descriptor: desc, size: size).map(Font.init) ?? .system(size: size, weight: weight, design: .monospaced)
        lock.lock()
        cache[key] = font
        lock.unlock()
        return font
    }
}

/// G9NVibe 暖米瓷白（Light）+ 暖石墨（Dark）工业精工色彩系统
struct VibePalette {
    let isDark: Bool

    var windowBg: Color {
        isDark ? Color(red: 0.098, green: 0.098, blue: 0.090) : Color(red: 0.961, green: 0.957, blue: 0.937)
    }
    var toolbarBg: Color {
        isDark ? Color(red: 0.122, green: 0.122, blue: 0.114) : Color(red: 0.988, green: 0.984, blue: 0.973)
    }
    var cardBg: Color {
        isDark ? Color(red: 0.133, green: 0.133, blue: 0.125) : Color.white
    }
    var insetBg: Color {
        isDark ? Color(red: 0.094, green: 0.094, blue: 0.086) : Color(red: 0.925, green: 0.918, blue: 0.886)
    }
    var hoverBg: Color {
        isDark ? Color(red: 0.173, green: 0.173, blue: 0.161) : Color(red: 0.973, green: 0.969, blue: 0.949)
    }
    var borderSoft: Color {
        isDark ? Color(red: 0.96, green: 0.957, blue: 0.937, opacity: 0.085) : Color(red: 0.086, green: 0.086, blue: 0.082, opacity: 0.09)
    }
    var borderMed: Color {
        isDark ? Color(red: 0.96, green: 0.957, blue: 0.937, opacity: 0.16) : Color(red: 0.086, green: 0.086, blue: 0.082, opacity: 0.16)
    }

    var ink1: Color {
        isDark ? Color(red: 0.957, green: 0.953, blue: 0.933) : Color(red: 0.086, green: 0.086, blue: 0.082)
    }
    var ink2: Color {
        isDark ? Color(red: 0.627, green: 0.616, blue: 0.580) : Color(red: 0.365, green: 0.357, blue: 0.325)
    }
    var ink3: Color {
        isDark ? Color(red: 0.424, green: 0.412, blue: 0.380) : Color(red: 0.573, green: 0.561, blue: 0.522)
    }

    /// 信号朱砂橙（遥控器与主交互强调色）
    var brand: Color {
        isDark ? Color(red: 1.0, green: 0.357, blue: 0.200) : Color(red: 0.902, green: 0.275, blue: 0.118)
    }
    var brandSoft: Color { brand.opacity(isDark ? 0.16 : 0.095) }
    var brandBorder: Color { brand.opacity(isDark ? 0.45 : 0.36) }

    /// 森林翠绿（Mac 麦克风与健康状态色）
    var macGreen: Color {
        isDark ? Color(red: 0.173, green: 0.776, blue: 0.494) : Color(red: 0.082, green: 0.518, blue: 0.322)
    }
    var macGreenSoft: Color { macGreen.opacity(isDark ? 0.15 : 0.10) }

    var amber: Color {
        isDark ? Color(red: 0.898, green: 0.627, blue: 0.141) : Color(red: 0.761, green: 0.471, blue: 0.012)
    }
    var amberSoft: Color { amber.opacity(isDark ? 0.16 : 0.11) }

    var meterIdle: Color {
        isDark ? Color(red: 0.96, green: 0.957, blue: 0.937, opacity: 0.09) : Color(red: 0.086, green: 0.086, blue: 0.082, opacity: 0.09)
    }
    var switchOff: Color {
        isDark ? Color(red: 0.243, green: 0.239, blue: 0.224) : Color(red: 0.812, green: 0.796, blue: 0.753)
    }
}

/// 40 根极细声学微光柱电平表（纯 CoreGraphics 2D 极轻量原生绘制，0 堆分配，绝不拉起 Metal 100MB 显存池）
struct MicroLevelMeterView: NSViewRepresentable {
    let db: Double
    let isRemoteStyle: Bool
    let palette: VibePalette
    var barHeight: CGFloat = 13

    func makeNSView(context: Context) -> LevelMeterNSView {
        let view = LevelMeterNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: LevelMeterNSView, context: Context) {
        nsView.barHeight = barHeight
        nsView.isRemoteStyle = isRemoteStyle
        nsView.idleColor = NSColor(palette.meterIdle)
        nsView.amberColor = NSColor(palette.amber)
        nsView.activeColor = NSColor(isRemoteStyle ? palette.brand : palette.macGreen)
        nsView.updateLevel(db: db)
    }
}

final class LevelMeterNSView: NSView {
    var barHeight: CGFloat = 13
    var isRemoteStyle: Bool = false
    var idleColor: NSColor = .lightGray
    var amberColor: NSColor = .systemOrange
    var activeColor: NSColor = .systemGreen
    private var litCount: Int = 0
    private let barCount = 40

    override var isOpaque: Bool { false }

    func updateLevel(db: Double) {
        let norm: Double
        if db <= -56 {
            norm = 0
        } else {
            norm = min(1.0, max(0.0, (db + 54.0) / 48.0))
        }
        let newLit = Int((norm * Double(barCount)).rounded())
        if newLit != litCount {
            litCount = newLit
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let spacing: CGFloat = 2.5
        let totalSpacing = spacing * CGFloat(barCount - 1)
        let barWidth = max(1.0, (bounds.width - totalSpacing) / CGFloat(barCount))
        let y = max(0, (bounds.height - barHeight) / 2.0)

        for i in 0..<barCount {
            let x = CGFloat(i) * (barWidth + spacing)
            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
            ctx.addPath(path)
            let color: NSColor
            if i >= litCount {
                color = idleColor
            } else if i > 33 {
                color = amberColor
            } else {
                color = activeColor
            }
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
        }
    }
}

/// 原生风格平滑切换开关
struct CeramicToggle: View {
    let isOn: Bool
    let tint: Color
    let palette: VibePalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? tint : palette.switchOff)
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(Color.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: Color.black.opacity(0.22), radius: 1.5, x: 0, y: 1)
                    .padding(2)
            }
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isOn)
        }
        .buttonStyle(.plain)
    }
}

/// 定制下拉触发药丸按钮（彻底取代系统丑陋原生 Picker）
struct CustomSelectPill: View {
    let text: String
    let isHighlighted: Bool
    let palette: VibePalette
    var minWidth: CGFloat = 152
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(text)
                    .font(VibeFont.label(12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .opacity(0.6)
            }
            .foregroundColor(isHighlighted ? palette.brand : palette.ink1)
            .padding(.horizontal, 10)
            .frame(minWidth: minWidth, minHeight: 28, maxHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHighlighted ? palette.brandSoft : palette.cardBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHighlighted ? palette.brandBorder : palette.borderMed, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
