import AppKit

/// G9NDaemon 后台极简常驻菜单栏控制器（纯 AppKit 原生 NSMenu，零 SwiftUI 依赖，常驻内存 < 1MB）
final class DaemonStatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    var onOpenConsoleRequested: (() -> Void)?
    var onPolicyChanged: ((MicRoutingPolicy) -> Void)?
    var onToggleMuteAllRequested: (() -> Void)?
    var onCheckUpdatesRequested: (() -> Void)?
    var onQuitDaemonRequested: (() -> Void)?

    private var currentPolicy: MicRoutingPolicy = .macOnly
    private var isDriverInstalled: Bool = false
    private var isAllMuted: Bool = false
    private var batteryLevel: Int? = nil

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        rebuildMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = Self.makeMenuBarIcon(accentColor: nil)
        button.toolTip = "G9NVibe 硬件守护 · 遥控器与语音就绪"
        menu.delegate = self
        statusItem.menu = menu
    }

    func updateState(
        policy: MicRoutingPolicy,
        driverInstalled: Bool,
        allMuted: Bool,
        battery: Int?,
        isRecording: Bool,
        isRemoteSource: Bool
    ) {
        self.currentPolicy = policy
        self.isDriverInstalled = driverInstalled
        self.isAllMuted = allMuted
        self.batteryLevel = battery

        // 更新状态栏图标高亮态（录音中点亮翠绿/橙色）
        guard let button = statusItem.button else { return }
        if isRecording {
            let color = isRemoteSource
                ? NSColor(srgbRed: 0.90, green: 0.27, blue: 0.12, alpha: 1.0)
                : NSColor(srgbRed: 0.08, green: 0.56, blue: 0.34, alpha: 1.0)
            button.image = Self.makeMenuBarIcon(accentColor: color)
        } else {
            button.image = Self.makeMenuBarIcon(accentColor: nil)
        }
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        // 1. 标题与状态提示
        let headerTitle: String
        if let bat = batteryLevel {
            headerTitle = "G9NVibe 守护中 · 遥控器电量 \(bat)%"
        } else {
            headerTitle = "G9NVibe 硬件守护"
        }
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        menu.addItem(NSMenuItem.separator())

        // 2. 唤起前台主控制台
        let openItem = NSMenuItem(title: "打开 G9NVibe 控制台", action: #selector(handleOpenConsole), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        // 3. 麦克风策略单选菜单
        let micSubmenu = NSMenu(title: "收音模式")
        for policy in MicRoutingPolicy.allCases {
            let item = NSMenuItem(title: policy.title, action: #selector(handleSelectPolicy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = policy
            if !isAllMuted && policy == currentPolicy {
                item.state = .on
            }
            if policy.requiresDriver && !isDriverInstalled {
                item.title += " (需驱动)"
            }
            micSubmenu.addItem(item)
        }
        let micParentItem = NSMenuItem(title: "收音模式：\(currentPolicy.title)", action: nil, keyEquivalent: "")
        micParentItem.submenu = micSubmenu
        menu.addItem(micParentItem)

        // 4. 双麦静音切换
        let muteTitle = isAllMuted ? "恢复麦克风收音" : "关闭双麦 (静音)"
        let muteItem = NSMenuItem(title: muteTitle, action: #selector(handleToggleMute), keyEquivalent: "")
        muteItem.target = self
        menu.addItem(muteItem)

        menu.addItem(NSMenuItem.separator())

        // 5. 检查更新
        let updateItem = NSMenuItem(title: "检查更新… (v\(AppStorage.appVersionString))", action: #selector(handleCheckUpdates), keyEquivalent: "u")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        // 6. 彻底退出
        let quitItem = NSMenuItem(title: "彻底退出 G9NVibe", action: #selector(handleQuitDaemon), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func handleOpenConsole() {
        onOpenConsoleRequested?()
    }

    @objc private func handleSelectPolicy(_ sender: NSMenuItem) {
        guard let policy = sender.representedObject as? MicRoutingPolicy else { return }
        onPolicyChanged?(policy)
    }

    @objc private func handleToggleMute() {
        onToggleMuteAllRequested?()
    }

    @objc private func handleCheckUpdates() {
        onCheckUpdatesRequested?()
    }

    @objc private func handleQuitDaemon() {
        onQuitDaemonRequested?()
    }

    /// 纯矢量绘制 18x18pt 博朗极简硬件方标（纯 AppKit CoreGraphics 2D 直绘，零显存）
    private static func makeMenuBarIcon(accentColor: NSColor?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let strokeColor: NSColor = (accentColor == nil) ? .black : .labelColor

            // 圆角硬件外框
            let frameRect = NSRect(x: 1.5, y: 2.2, width: 15.0, height: 13.6)
            let framePath = NSBezierPath(roundedRect: frameRect, xRadius: 3.6, yRadius: 3.6)
            framePath.lineWidth = 1.45
            strokeColor.setStroke()
            framePath.stroke()

            // 左侧语音实体圆键
            let btnRect = NSRect(x: 3.8, y: 6.2, width: 5.6, height: 5.6)
            let btnPath = NSBezierPath(ovalIn: btnRect)
            (accentColor ?? strokeColor).setFill()
            btnPath.fill()

            // 右侧 2 列 × 3 行微孔阵列
            strokeColor.setFill()
            let dotR: CGFloat = 0.85
            let cols: [CGFloat] = [11.6, 13.9]
            let rows: [CGFloat] = [6.3, 9.0, 11.7]
            for cx in cols {
                for cy in rows {
                    let dot = NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2))
                    dot.fill()
                }
            }
            return true
        }
        image.isTemplate = (accentColor == nil)
        return image
    }
}
