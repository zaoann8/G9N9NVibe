import AppKit
import SwiftUI

/// 主工作台根视图（一体化顶栏 + 音频 / 按键映射两页切换）
struct MainConsoleRootView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: RemoteMappingStore
    @Environment(\.colorScheme) private var systemScheme
    @State private var isUpdateHovered = false
    @State private var bannerDismissedVersion: String? = nil

    private var isDark: Bool {
        switch vm.themePreference {
        case .light: return false
        case .dark: return true
        case .system: return systemScheme == .dark
        }
    }

    private var palette: VibePalette {
        VibePalette(isDark: isDark)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 原生一体化工具栏
            toolbar
            // 刚刚覆盖升级成功后的明显翠绿成功横幅（用户一眼确认已更新至新版）
            if let upgraded = vm.upgradedBannerInfo {
                upgradedSuccessBanner(from: upgraded.from, to: upgraded.to)
            }
            // 发现新版本时，在顶栏下方滑出醒目可关闭的更新提醒横幅，确保用户一眼看到
            if case .available(let info) = vm.updateState, bannerDismissedVersion != info.version {
                updateAvailableBanner(info)
            }
            // 内容画布：全窗口流式自适应铺满，窗口放大时内部所有卡片与微光柱同步优雅放大舒展
            ZStack(alignment: .bottom) {
                Group {
                    switch vm.currentPage {
                    case .audio:
                        AudioConsoleView(vm: vm, palette: palette)
                    case .mapping:
                        KeyMappingView(vm: vm, store: store, palette: palette)
                    case .longPress:
                        LongPressView(vm: vm, store: store, palette: palette)
                    case .autoScene:
                        AutoAppSceneView(vm: vm, store: store, palette: palette)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 全局轻量底部操作反馈气泡（2.2 秒自动淡出，不遮挡操作）
                if let toast = vm.toastMessage {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(vm.toastIsPositive ? palette.macGreen : palette.amber)
                            .frame(width: 7, height: 7)
                        Text(toast)
                            .font(VibeFont.label(12, weight: .semibold))
                            .foregroundColor(palette.ink1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(palette.cardBg))
                    .overlay(Capsule().stroke(vm.toastIsPositive ? palette.macGreen.opacity(0.45) : palette.borderMed, lineWidth: 1))
                    .shadow(color: Color.black.opacity(0.14), radius: 10, y: 4)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: vm.toastMessage)
        }
        .frame(minWidth: 840, idealWidth: 960, minHeight: 600, idealHeight: 660)
        .background(palette.windowBg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.borderSoft, lineWidth: 1)
        )
        .preferredColorScheme(vm.themePreference == .system ? nil : (vm.themePreference == .dark ? .dark : .light))
        .sheet(isPresented: $vm.showOnboarding) {
            OnboardingView(vm: vm, palette: palette)
        }
        .sheet(isPresented: $vm.showUpdateSheet) {
            UpdateSheetView(vm: vm, palette: palette)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            // 手绘苹果原厂标准红黄绿三色交通灯按钮（彻底消灭 ThemeWidgetControlViewService）
            AppleTrafficLightsView(
                onClose: {
                    NSApp.keyWindow?.performClose(nil)
                },
                onMinimize: {
                    NSApp.keyWindow?.miniaturize(nil)
                },
                onZoom: {
                    NSApp.keyWindow?.zoom(nil)
                }
            )
            .padding(.leading, 2)

            HStack(spacing: 8) {
                if let appIcon = NSApp.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 26, height: 26)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(palette.ink1)
                            .frame(width: 24, height: 24)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundColor(palette.cardBg)
                    }
                }
                Text("G9NVibe")
                    .font(VibeFont.brand(15))
                    .tracking(0.2)
                    .foregroundColor(palette.ink1)
                // 清晰可识别的手动检查更新 / 新版升级按钮胶囊
                Button {
                    vm.openUpdateDialog()
                } label: {
                    switch vm.updateState {
                    case .available(let info):
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(vm.t("新版 \(info.tagName)", "New \(info.tagName)"))
                                .font(VibeFont.label(11, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Capsule().fill(palette.brand))
                        .shadow(color: palette.brand.opacity(0.32), radius: 4, y: 1)
                        .contentShape(Rectangle())
                    case .checking:
                        HStack(spacing: 5) {
                            ProgressView().scaleEffect(0.5)
                                .frame(width: 11, height: 11)
                            Text(vm.t("检查中…", "Checking…"))
                                .font(VibeFont.label(10.5, weight: .medium))
                        }
                        .foregroundColor(palette.ink2)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(palette.insetBg))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.borderMed, lineWidth: 1))
                        .contentShape(Rectangle())
                    default:
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 10, weight: .semibold))
                            Text("v\(AppStorage.appVersionString)")
                                .font(VibeFont.mono(10.5, weight: .medium))
                            Text(vm.t("· 更新", "· Update"))
                                .font(VibeFont.label(10.5, weight: .semibold))
                        }
                        .foregroundColor(isUpdateHovered ? palette.ink1 : palette.ink2)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(isUpdateHovered ? palette.cardBg : palette.insetBg))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isUpdateHovered ? palette.brandBorder : palette.borderMed, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .onHover { isUpdateHovered = $0 }
                .help(vm.t("点击手动检查软件更新（快捷键 ⌘U）", "Click to check for updates (⌘U)"))
            }
            .fixedSize()

            Spacer(minLength: 8)

            // 中央 4 项清晰分段导航：音频 · 按键映射 · 长按扩展 · 自动场景
            HStack(spacing: 2) {
                navTab(.audio, title: vm.t("音频", "Audio"), icon: "slider.horizontal.3")
                navTab(.mapping, title: vm.t("按键映射", "Key Map"), icon: "keyboard")
                navTab(.longPress, title: vm.t("长按扩展", "Hold Keys"), icon: "hand.tap")
                navTab(.autoScene, title: vm.t("自动场景", "Auto App"), icon: "sparkles.rectangle.stack")
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.insetBg))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.borderSoft, lineWidth: 1))
            .fixedSize()

            Spacer(minLength: 8)

            // 右侧精工工具组：开机自启 + 中英文切换 + 主题切换 + 引导问号 + 状态胶囊（全部整块热区可点）
            HStack(spacing: 6) {
                // 开机自启动（鲜明圆点 + 开/关文字 + 弹性动效 + 底部 Toast 确认）
                Button {
                    vm.toggleLaunchAtLogin()
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(vm.launchAtLogin ? palette.macGreen : palette.ink3.opacity(0.5))
                            .frame(width: 6.5, height: 6.5)
                        Text(vm.launchAtLogin ? vm.t("自启:开", "Auto:On") : vm.t("自启:关", "Auto:Off"))
                            .font(VibeFont.label(11, weight: .semibold))
                    }
                    .foregroundColor(vm.launchAtLogin ? palette.macGreen : palette.ink2)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(vm.launchAtLogin ? palette.macGreenSoft : palette.insetBg))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(vm.launchAtLogin ? palette.macGreen.opacity(0.50) : palette.borderSoft, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(.easeInOut(duration: 0.16), value: vm.launchAtLogin)
                .help(vm.launchAtLogin
                    ? vm.t("开机自启动已开启（点击关闭）", "Launch at Login: On (click to disable)")
                    : vm.t("开机自启动已关闭（点击开启）", "Launch at Login: Off (click to enable)"))

                // 中英文一键切换
                Button {
                    vm.toggleLanguage()
                } label: {
                    Text(vm.language.toggleLabel)
                        .font(VibeFont.mono(11, weight: .semibold))
                        .foregroundColor(palette.ink2)
                        .frame(width: 28, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(palette.insetBg))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.borderSoft, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(vm.t("切换为英文界面 (English)", "Switch to Chinese (中文)"))

                // 浅色 / 暗色主题切换
                Button {
                    vm.toggleTheme()
                } label: {
                    Image(systemName: isDark ? "sun.max.fill" : "moon.fill")
                        .font(.system(size: 11.5))
                        .foregroundColor(palette.ink2)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(palette.insetBg))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.borderSoft, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(vm.t("切换暖米瓷白 / 暖石墨主题", "Toggle Light / Dark Theme"))

                // 重看互动新手引导
                Button {
                    vm.showOnboarding = true
                } label: {
                    Image(systemName: "questionmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(palette.ink2)
                        .frame(width: 24, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(palette.insetBg))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.borderSoft, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(vm.t("打开互动使用引导", "Open Interactive Guide"))

                let missing = vm.permissions.missingCount
                HStack(spacing: 5) {
                    Circle()
                        .fill(missing > 0 ? palette.amber : palette.macGreen)
                        .frame(width: 7, height: 7)
                    Text(missing > 0
                        ? vm.t("缺 \(missing) 项权限", "\(missing) Perms")
                        : vm.t("正在运行", "Active"))
                        .font(VibeFont.label(11.5, weight: .semibold))
                        .foregroundColor(missing > 0 ? palette.amber : palette.macGreen)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(missing > 0 ? palette.amberSoft : palette.macGreenSoft))
            }
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(palette.toolbarBg)
        .overlay(Divider().background(palette.borderSoft), alignment: .bottom)
    }

    private func upgradedSuccessBanner(from oldVersion: String, to newVersion: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(palette.macGreen)
            Text(vm.t(
                "已成功更新至 G9NVibe v\(newVersion)（从 v\(oldVersion) 升级 · 全部系统权限与自定义键位已完整保留）",
                "Updated to G9NVibe v\(newVersion) (from v\(oldVersion) · All permissions & key mappings preserved)"
            ))
            .font(VibeFont.label(12, weight: .semibold))
            .foregroundColor(palette.ink1)
            .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                vm.upgradedBannerInfo = nil
            } label: {
                Text(vm.t("知道了", "Got It"))
                    .font(VibeFont.label(11.5, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.macGreen))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(palette.macGreenSoft)
        .overlay(Divider().background(palette.macGreen.opacity(0.38)), alignment: .bottom)
    }

    private func updateAvailableBanner(_ info: ReleaseUpdateInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(palette.brand)
            Text(vm.t(
                "发现新版本 G9NVibe \(info.tagName)（当前 v\(AppStorage.appVersionString)），支持 SHA-256 校验与无损自动覆盖升级",
                "New version G9NVibe \(info.tagName) available (current v\(AppStorage.appVersionString)) with one-click verified upgrade"
            ))
            .font(VibeFont.label(12, weight: .semibold))
            .foregroundColor(palette.ink1)
            .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                vm.openUpdateDialog()
            } label: {
                Text(vm.t("立即查看并更新", "Update Now"))
                    .font(VibeFont.label(11.5, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.brand))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                bannerDismissedVersion = info.version
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(palette.ink3)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(vm.t("暂时隐藏此横幅", "Dismiss banner"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(palette.brandSoft)
        .overlay(Divider().background(palette.brandBorder), alignment: .bottom)
    }

    private func navTab(_ page: AppViewModel.Page, title: String, icon: String) -> some View {
        let active = vm.currentPage == page
        return Button {
            vm.selectPage(page)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(VibeFont.label(12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(active ? palette.ink1 : palette.ink2)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(active ? palette.cardBg : Color.clear)
                    .shadow(color: active ? Color.black.opacity(0.08) : .clear, radius: 2, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 可深度解绑销毁的 SwiftUI 托管容器（关窗时置空 rootView，彻底摧毁 SwiftUI AttributeGraph 引用图）
final class PurgeableHostingController: NSHostingController<AnyView> {
    init<V: View>(root: V) {
        super.init(rootView: AnyView(root))
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func purgeViewGraph() {
        self.rootView = AnyView(EmptyView())
        self.view.removeFromSuperview()
    }
}

/// 极低内存主窗口管理器：
/// 仅在用户主动打开主窗口时创建 NSWindow + NSHostingView；
/// 一旦用户关闭窗口，立即通过 purgeViewGraph() 彻底析构所有 SwiftUI 视图节点与闭包缓存，
/// 保持单进程架构下极速秒开与极致干净的常驻内存！
final class MainWindowController: NSObject, NSWindowDelegate {
    private let viewModel: AppViewModel
    private let mappingStore: RemoteMappingStore
    private var window: NSWindow?
    private var hosting: PurgeableHostingController?

    var onVisibilityChanged: ((Bool) -> Void)?

    init(viewModel: AppViewModel, mappingStore: RemoteMappingStore) {
        self.viewModel = viewModel
        self.mappingStore = mappingStore
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func showWindow() {
        viewModel.refreshPermissions()

        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            onVisibilityChanged?(true)
            return
        }

        let rootView = MainConsoleRootView(vm: viewModel, store: mappingStore)
        let host = PurgeableHostingController(root: rootView)
        host.preferredContentSize = NSSize(width: 960, height: 660)
        self.hosting = host

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 660),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "G9NVibe"
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.fullScreenNone]
        win.contentViewController = host
        win.setContentSize(NSSize(width: 960, height: 660))
        win.minSize = NSSize(width: 840, height: 600)
        win.delegate = self
        win.center()

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onVisibilityChanged?(true)
        AppLog.write("UI", "主窗口已按需创建")
    }

    func windowWillClose(_ notification: Notification) {
        // 方案 C 核心：关窗时彻底析构 SwiftUI 视图树，单进程纯净常驻
        window?.orderOut(nil)
        hosting?.purgeViewGraph()
        hosting = nil
        window?.contentViewController = nil
        window?.delegate = nil
        window = nil
        onVisibilityChanged?(false)
        AppLog.write("UI", "主窗口已关闭，已彻底净化视图树并执行内核深度内存回收")

        // 调用 Darwin XNU 内核专用深度内存压降
        MemoryReclaim.performDeepPurge()
    }
}

/// 纯手绘苹果原厂标准红黄绿三色交通灯按钮：
/// - 彻底摆脱 AppKit 标题栏托管机制，从源头上 100% 杜绝 ThemeWidgetControlViewService！
/// - 悬停时浮现 × / − / ⤢ 微图标，支持关闭、最小化、缩放，触感与手感与 macOS 官方一模一样。
struct AppleTrafficLightsView: View {
    @State private var isHovered = false
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void

    var body: some View {
        HStack(spacing: 7.5) {
            // 红色关闭按钮
            Button(action: onClose) {
                ZStack {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.36, blue: 0.33))
                    Circle()
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                    if isHovered {
                        Image(systemName: "xmark")
                            .font(.system(size: 6.5, weight: .bold))
                            .foregroundColor(Color.black.opacity(0.68))
                    }
                }
                .frame(width: 12, height: 12)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭窗口 (⌘W)")

            // 黄色最小化按钮
            Button(action: onMinimize) {
                ZStack {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.74, blue: 0.18))
                    Circle()
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                    if isHovered {
                        Image(systemName: "minus")
                            .font(.system(size: 6.5, weight: .bold))
                            .foregroundColor(Color.black.opacity(0.68))
                    }
                }
                .frame(width: 12, height: 12)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("最小化")

            // 绿色适度缩放按钮
            Button(action: onZoom) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.16, green: 0.80, blue: 0.25))
                    Circle()
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
                    if isHovered {
                        Image(systemName: "arrow.up.left.and.down.right.and.arrow.down.right.and.up.left")
                            .font(.system(size: 5.5, weight: .bold))
                            .foregroundColor(Color.black.opacity(0.68))
                    }
                }
                .frame(width: 12, height: 12)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("缩放窗口")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .onHover { isHovered = $0 }
    }
}
