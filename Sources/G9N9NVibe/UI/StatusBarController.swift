import AppKit
import SwiftUI

/// 纯 AppKit 极简常驻菜单栏控制器（平时不加载主窗口，常驻极低内存）
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let viewModel: AppViewModel
    private var popover: NSPopover?

    var onOpenMainWindow: (() -> Void)?
    var onCheckUpdatesRequested: (() -> Void)?
    var onQuitRequested: (() -> Void)?

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = Self.makeMenuBarIcon(accentColor: nil)
        button.toolTip = "G9NVibe · 点击切换麦克风或打开控制台"
        button.target = self
        button.action = #selector(togglePopover(_:))
    }

    func updateIconState(isRecording: Bool, isRemoteSource: Bool) {
        guard let button = statusItem.button else { return }
        if isRecording {
            let color = isRemoteSource
                ? NSColor(srgbRed: 0.90, green: 0.27, blue: 0.12, alpha: 1.0)
                : NSColor(srgbRed: 0.08, green: 0.56, blue: 0.34, alpha: 1.0)
            button.image = Self.makeMenuBarIcon(accentColor: color)
        } else {
            button.image = Self.makeMenuBarIcon(accentColor: nil)
        }
    }

    /// 纯矢量绘制 18x18pt 博朗 Dieter Rams 极简硬件方标（左侧语音圆键 + 右侧 3x2 精密微孔，完美呼应 App Icon）
    /// 待机态使用 isTemplate = true 自动适配浅色/暗色菜单栏；录音态仅点亮左侧语音圆键（翠绿/朱砂橙）
    private static func makeMenuBarIcon(accentColor: NSColor?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let strokeColor: NSColor = (accentColor == nil) ? .black : .labelColor

            // 精致圆角硬件外框
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

            // 右侧 2 列 × 3 行精密微孔阵列
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

    @objc private func togglePopover(_ sender: AnyObject?) {
        if let pop = popover, pop.isShown {
            closePopover()
            return
        }
        guard let button = statusItem.button else { return }
        viewModel.refreshPermissions()

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 256, height: 324)
        pop.contentViewController = NSHostingController(
            rootView: MenuBarQuickCardView(
                vm: viewModel,
                onOpenMain: { [weak self] in
                    self?.closePopover()
                    self?.onOpenMainWindow?()
                },
                onCheckUpdates: { [weak self] in
                    self?.closePopover()
                    self?.onCheckUpdatesRequested?()
                },
                onClose: { [weak self] in
                    self?.closePopover()
                },
                onQuit: { [weak self] in
                    self?.closePopover()
                    self?.onQuitRequested?()
                }
            )
        )
        self.popover = pop
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func closePopover() {
        popover?.performClose(nil)
        // 关闭即释放菜单栏 Popover 视图树
        popover?.contentViewController = nil
        popover = nil
    }
}

private struct MenuBarQuickCardView: View {
    @ObservedObject var vm: AppViewModel
    @Environment(\.colorScheme) private var systemScheme
    let onOpenMain: () -> Void
    let onCheckUpdates: () -> Void
    let onClose: () -> Void
    let onQuit: () -> Void

    private var palette: VibePalette {
        let isDark: Bool
        switch vm.themePreference {
        case .light: isDark = false
        case .dark: isDark = true
        case .system: isDark = (systemScheme == .dark)
        }
        return VibePalette(isDark: isDark)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("G9NVibe")
                    .font(VibeFont.brand(13))
                    .foregroundColor(palette.ink1)
                if let battery = vm.remoteBatteryLevel {
                    Text("\(battery)%")
                        .font(VibeFont.mono(10, weight: .semibold))
                        .foregroundColor(battery < 20 ? palette.amber : palette.macGreen)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(battery < 20 ? palette.amberSoft : palette.macGreenSoft))
                }
                Spacer()
                Text(vm.isAllMicsClosed
                    ? vm.t("已关双麦", "Muted")
                    : (vm.driverInstalled ? vm.t("双麦就绪", "Dual Ready") : vm.t("仅电脑麦", "Mac Mic Only")))
                    .font(VibeFont.label(11, weight: .semibold))
                    .foregroundColor(vm.isAllMicsClosed ? palette.brand : palette.macGreen)
            }
            .padding(.horizontal, 4)

            Divider().background(palette.borderSoft)

            VStack(spacing: 4) {
                ForEach(MicRoutingPolicy.allCases) { p in
                    let active = !vm.isAllMicsClosed && vm.micPolicy == p
                    Button {
                        vm.selectPolicy(p)
                        onClose()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.title(lang: vm.language))
                                    .font(VibeFont.label(12.5, weight: .semibold))
                                Text(p.requiresDriver && !vm.driverInstalled
                                    ? vm.t("需一键启用驱动", "Requires built-in driver")
                                    : p.subtitle(lang: vm.language))
                                    .font(VibeFont.caption(10.5))
                                    .foregroundColor(palette.ink3)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if active {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                            }
                        }
                        .foregroundColor(active ? palette.brand : palette.ink1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(active ? palette.brandSoft : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().background(palette.borderSoft)

            // 显眼的手动检查更新 / 新版提醒条
            Button {
                onCheckUpdates()
            } label: {
                HStack(spacing: 6) {
                    if case .available(let info) = vm.updateState {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(palette.brand)
                        Text(vm.t("发现新版本 \(info.tagName)，点击更新", "Update \(info.tagName) Available"))
                            .font(VibeFont.label(11.5, weight: .semibold))
                            .foregroundColor(palette.brand)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(palette.ink2)
                        Text(vm.t("检查更新（v\(AppStorage.appVersionString)）", "Check for Updates (v\(AppStorage.appVersionString))"))
                            .font(VibeFont.label(11.5, weight: .medium))
                            .foregroundColor(palette.ink2)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(vm.updateState.hasAvailableUpdate ? palette.brandSoft : palette.insetBg.opacity(0.65)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack {
                Button {
                    onOpenMain()
                } label: {
                    Text(vm.t("打开主控制台", "Open Console"))
                        .font(VibeFont.label(12, weight: .semibold))
                        .foregroundColor(palette.ink1)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    vm.toggleMuteAll()
                } label: {
                    Text(vm.isAllMicsClosed ? vm.t("恢复麦", "Unmute") : vm.t("关双麦", "Mute"))
                        .font(VibeFont.label(11.5, weight: .semibold))
                        .foregroundColor(vm.isAllMicsClosed ? palette.macGreen : palette.brand)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    onQuit()
                } label: {
                    Text(vm.t("退出", "Quit"))
                        .font(VibeFont.label(12, weight: .regular))
                        .foregroundColor(palette.ink3)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .frame(width: 256)
        .background(palette.cardBg)
    }
}
