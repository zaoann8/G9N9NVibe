import AppKit
import ApplicationServices
import AVFoundation
import CoreBluetooth
import Foundation

/// 权限体检单项状态
struct PermissionStatusSnapshot: Equatable {
    var microphoneGranted: Bool = false
    var accessibilityGranted: Bool = false
    var inputMonitoringGranted: Bool = false
    var bluetoothGranted: Bool = false

    var missingCount: Int {
        var c = 0
        if !accessibilityGranted { c += 1 }
        if !inputMonitoringGranted { c += 1 }
        if !bluetoothGranted { c += 1 }
        return c
    }
}

/// 主应用状态协调模型（负责驱动 UI 展示与底层子系统交互，不持有任何重型视图对象）
final class AppViewModel: ObservableObject {
    enum Page: String, CaseIterable {
        case audio
        case mapping
        case longPress
        case autoScene
    }

    @Published var currentPage: Page = .audio
    @Published var themePreference: AppThemePreference = AppStorage.themePreference
    @Published var language: AppLanguage = AppStorage.language
    @Published var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @Published var showOnboarding: Bool = false
    /// 软件更新状态与更新弹窗显隐
    @Published var updateState: AppUpdateState = .idle
    @Published var showUpdateSheet: Bool = false
    /// 刚刚覆盖升级完成后的明显翠绿成功横幅提示（记录从旧版 -> 新版，点击「知道了」收起）
    @Published var upgradedBannerInfo: (from: String, to: String)? = nil
    @Published var driverInstalled: Bool = false
    @Published var micPolicy: MicRoutingPolicy = AppStorage.micPolicy
    @Published var voiceInputMethod: VoiceInputMethod = VoiceInputMethod.current
    @Published var triggerShortcut: VoiceTriggerShortcut = AppStorage.voiceTriggerShortcut
    @Published var triggerMode: InputTriggerMode = AppStorage.inputTriggerMode

    @Published var bleConnected: Bool = false
    @Published var hidConnected: Bool = false
    /// G9N9N 硬件真实蓝牙电量百分比（0...100，未连或固件未上报时为 nil）
    @Published var remoteBatteryLevel: Int? = nil
    /// 遥控器收音灵敏度 3 档（近场 +14dB / 标准 +20dB / 远场 +26dB）
    @Published var remoteGainPreset: RemoteMicGainPreset = AppStorage.remoteMicGainPreset
    /// 自动切换预设时当前匹配到的前台应用名（用于柔和状态提示）
    @Published var autoSwitchedAppName: String? = nil
    @Published var isRecording: Bool = false
    @Published var activeTriggerSource: SessionTriggerSource = .none
    @Published var sessionStatusText: String = "等待录音"
    @Published var doubaoRouteMismatch: Bool = false

    @Published var macLevelDb: Double = -120
    @Published var remoteLevelDb: Double = -120
    @Published var outputLevelDb: Double = -120

    @Published var selectedButtonID: String = "07"
    @Published var voiceKeyLivePulse: Bool = false
    /// 遥控器底部白色物理 LED 指示灯脉冲反馈（按键/语音触发时高亮闪烁）
    @Published var remoteLedPulse: Bool = false
    /// 底部轻量操作反馈提示气泡（2.2 秒自动淡出）
    @Published var toastMessage: String? = nil
    @Published var toastIsPositive: Bool = true
    @Published var permissions = PermissionStatusSnapshot()
    @Published var isDriverBusy: Bool = false
    /// 免驱模式下用户手动暂停/开启 Mac 麦克风电平显示的开关状态
    @Published var macMonitoringEnabled: Bool = true
    /// 驱动态下是否双麦同时关闭（全部暂停收音，系统默认麦完全还原不受接管）
    @Published var allMuted: Bool = false
    /// 当前是否正处于主界面「触发试说测试」激活态
    @Published var isTestSpeaking: Bool = false

    private var toastHideWork: DispatchWorkItem?
    private var ledPulseWork: DispatchWorkItem?

    // 由 AppController 注入的动作回调
    var onPolicyChanged: ((MicRoutingPolicy) -> Void)?
    var onInputMethodChanged: ((VoiceInputMethod) -> Void)?
    var onTriggerShortcutChanged: ((VoiceTriggerShortcut) -> Void)?
    var onTriggerModeChanged: ((InputTriggerMode) -> Void)?
    var onMappingEnabledChanged: ((Bool) -> Void)?
    var onRequestInstallDriver: ((MicRoutingPolicy) -> Void)?
    var onRequestUninstallDriver: (() -> Void)?
    var onTestSpeakRequested: (() -> Void)?
    var onPageChanged: ((Page) -> Void)?
    var onMacMonitoringToggled: ((Bool) -> Void)?
    var onAllMutedChanged: ((Bool) -> Void)?
    var onRemoteGainChanged: ((RemoteMicGainPreset) -> Void)?

    var isMacEnabled: Bool {
        if !driverInstalled { return macMonitoringEnabled }
        if allMuted { return false }
        return micPolicy == .macOnly || micPolicy == .smartByTriggerSource || micPolicy == .dualMix
    }

    var isRemoteEnabled: Bool {
        guard driverInstalled, !allMuted else { return false }
        return micPolicy == .remoteOnly || micPolicy == .smartByTriggerSource || micPolicy == .dualMix
    }

    /// 双麦当前是否处于完全关闭状态（兼容免驱态与驱动态）
    var isAllMicsClosed: Bool {
        if driverInstalled {
            return allMuted
        }
        return !macMonitoringEnabled
    }

    /// 轻量中英文双语翻译 helper（零资源包开销，切换瞬间全局刷新）
    func t(_ zh: String, _ en: String) -> String {
        language == .zh ? zh : en
    }

    /// 展示自动淡出的优雅操作反馈气泡（默认 2.2 秒，重要成功提示可自定义时长）
    func showToast(_ message: String, positive: Bool = true, duration: TimeInterval = 2.2) {
        toastHideWork?.cancel()
        toastIsPositive = positive
        toastMessage = message
        let work = DispatchWorkItem { [weak self] in
            self?.toastMessage = nil
        }
        toastHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// 触发 G9N9N 遥控器底部白色 LED 实体灯脉冲闪烁反馈
    func triggerRemoteLedPulse() {
        ledPulseWork?.cancel()
        remoteLedPulse = true
        let work = DispatchWorkItem { [weak self] in
            self?.remoteLedPulse = false
        }
        ledPulseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
    }

    func toggleLanguage() {
        language = (language == .zh) ? .en : .zh
        AppStorage.language = language
        showToast(language == .zh ? "已切换为简体中文" : "Switched to English")
    }

    func toggleLaunchAtLogin() {
        let next = !launchAtLogin
        LaunchAtLogin.setEnabled(next)
        launchAtLogin = LaunchAtLogin.isEnabled
        if launchAtLogin {
            showToast(t("✓ 已开启开机自启动（下次开机自动后台常驻）", "✓ Launch at Login enabled"))
        } else {
            showToast(t("已关闭开机自启动", "Launch at Login disabled"), positive: false)
        }
    }

    func completeOnboarding() {
        AppStorage.hasCompletedOnboarding = true
        showOnboarding = false
    }

    func openUpdateDialog() {
        showUpdateSheet = true
        if case .available = updateState {
            return
        }
        if !updateState.isBusy {
            AppUpdater.shared.checkForUpdates(userInitiated: true)
        }
    }

    func checkUpdatesManually() {
        AppUpdater.shared.checkForUpdates(userInitiated: true)
    }

    func startAutomaticUpdate(_ info: ReleaseUpdateInfo) {
        AppUpdater.shared.startDownloadAndInstall(info)
    }

    func cancelAutomaticUpdate() {
        AppUpdater.shared.cancelActiveDownload()
    }

    /// 一键关闭 / 恢复双麦（同时支持免驱态与驱动态，关闭后彻底还原系统默认麦不受接管）
    func toggleMuteAll() {
        if !driverInstalled {
            let wasClosed = !macMonitoringEnabled
            toggleMacChannel()
            if wasClosed {
                allMuted = false
                onAllMutedChanged?(false)
            }
            showToast(
                isAllMicsClosed
                    ? t("已关闭双麦（系统原物理麦未接管）", "Mics muted (system mic untouched)")
                    : t("✓ 已恢复 MacBook 麦克风", "✓ MacBook Microphone restored"),
                positive: !isAllMicsClosed
            )
            return
        }
        let next = !allMuted
        allMuted = next
        if !next {
            macMonitoringEnabled = true
        }
        if next {
            macLevelDb = -120
            remoteLevelDb = -120
            outputLevelDb = -120
        }
        onAllMutedChanged?(next)
        showToast(
            next
                ? t("已一键关闭双麦（系统原物理麦已还原）", "Both mics muted (system mic restored)")
                : t("✓ 已恢复双麦收音路由", "✓ Microphone routing restored"),
            positive: !next
        )
    }

    func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let acc = AXIsProcessTrusted()
        let inputMon = CGPreflightListenEventAccess()
        let bt = (CBManager.authorization == .allowedAlways)
        permissions = PermissionStatusSnapshot(
            microphoneGranted: mic,
            accessibilityGranted: acc,
            inputMonitoringGranted: inputMon,
            bluetoothGranted: bt
        )
    }

    func openSystemPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestMicrophonePermissionIfNeeded() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.refreshPermissions() }
            }
        } else {
            openSystemPrivacyPane("Privacy_Microphone")
        }
    }

    func requestInputMonitoringPermission() {
        _ = CGRequestListenEventAccess()
        openSystemPrivacyPane("Privacy_ListenEvent")
    }

    func requestAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        openSystemPrivacyPane("Privacy_Accessibility")
    }

    func toggleTheme() {
        themePreference = (themePreference == .dark) ? .light : .dark
        AppStorage.themePreference = themePreference
    }

    func selectPage(_ page: Page) {
        guard currentPage != page else { return }
        currentPage = page
        onPageChanged?(page)
    }

    func selectPolicy(_ policy: MicRoutingPolicy) {
        if !driverInstalled && policy.requiresDriver {
            onRequestInstallDriver?(policy)
            return
        }
        let wasClosed = isAllMicsClosed
        if !driverInstalled {
            // 免驱态下点击「仅电脑麦」时，若此前已关闭双麦则立即恢复 MacBook 麦克风
            if !macMonitoringEnabled {
                macMonitoringEnabled = true
                onMacMonitoringToggled?(true)
            }
            if allMuted {
                allMuted = false
                onAllMutedChanged?(false)
            }
        } else if allMuted {
            allMuted = false
            macMonitoringEnabled = true
            onAllMutedChanged?(false)
        }
        micPolicy = policy
        AppStorage.micPolicy = policy
        onPolicyChanged?(policy)
        if wasClosed {
            showToast(t("✓ 已开启 \(policy.title(lang: .zh))", "✓ Enabled \(policy.title(lang: .en))"))
        }
    }

    func toggleMacChannel() {
        if !driverInstalled {
            // 免驱模式下真实切换电脑麦监听开关（关闭即停止采麦与电平预览）
            macMonitoringEnabled.toggle()
            if !macMonitoringEnabled {
                macLevelDb = -120
                outputLevelDb = -120
            }
            onMacMonitoringToggled?(macMonitoringEnabled)
            return
        }
        // 驱动态下支持独立双关：两路都可关闭，同时彻底还原系统默认麦不受接管
        if allMuted {
            allMuted = false
            onAllMutedChanged?(false)
            selectPolicy(.macOnly)
        } else if isMacEnabled && isRemoteEnabled {
            selectPolicy(.remoteOnly)
        } else if isMacEnabled && !isRemoteEnabled {
            allMuted = true
            macLevelDb = -120
            outputLevelDb = -120
            onAllMutedChanged?(true)
        } else {
            selectPolicy(.smartByTriggerSource)
        }
    }

    func toggleRemoteChannel() {
        guard driverInstalled else {
            onRequestInstallDriver?(.smartByTriggerSource)
            return
        }
        if allMuted {
            allMuted = false
            onAllMutedChanged?(false)
            selectPolicy(.remoteOnly)
        } else if isRemoteEnabled && isMacEnabled {
            selectPolicy(.macOnly)
        } else if isRemoteEnabled && !isMacEnabled {
            allMuted = true
            remoteLevelDb = -120
            outputLevelDb = -120
            onAllMutedChanged?(true)
        } else {
            selectPolicy(.smartByTriggerSource)
        }
    }

    func selectInputMethod(_ method: VoiceInputMethod) {
        voiceInputMethod = method
        VoiceInputMethod.select(method)
        onInputMethodChanged?(method)
    }

    func selectTriggerShortcut(_ shortcut: VoiceTriggerShortcut) {
        triggerShortcut = shortcut
        AppStorage.voiceTriggerShortcut = shortcut
        onTriggerShortcutChanged?(shortcut)
    }

    func selectTriggerMode(_ mode: InputTriggerMode) {
        triggerMode = mode
        AppStorage.inputTriggerMode = mode
        onTriggerModeChanged?(mode)
    }

    func selectRemoteGain(_ preset: RemoteMicGainPreset) {
        remoteGainPreset = preset
        AppStorage.remoteMicGainPreset = preset
        onRemoteGainChanged?(preset)
        showToast(t(
            "✓ 遥控器灵敏度已设为「\(preset.title(lang: .zh)) \(preset.dbLabel)」",
            "✓ Remote Mic Gain: \(preset.title(lang: .en)) (\(preset.dbLabel))"
        ))
    }

    func formatDb(_ db: Double) -> String {
        db <= -59 ? "-∞ dB" : "\(Int(db.rounded())) dB"
    }
}
