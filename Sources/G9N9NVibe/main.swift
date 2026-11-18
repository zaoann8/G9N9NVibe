import AppKit
import Foundation

/// G9N9N-Vibe 主程序控制器（纯 AppKit 后台常驻底座 + 按需创建/关闭即销毁主窗口）
final class AppController: NSObject, NSApplicationDelegate {
    private let viewModel = AppViewModel()
    private let mappingStore = RemoteMappingStore.shared
    private let bleBridge = BLEBridge()
    private let hidBridge = G9N9NHIDBridge()
    private let keyboardMonitor = KeyboardTapMonitor()
    private let audioStateMonitor = AudioStateMonitor()
    private lazy var sessionCoordinator = VoiceSessionCoordinator(audioState: audioStateMonitor)
    private lazy var mainWindowController = MainWindowController(viewModel: viewModel, mappingStore: mappingStore)
    private lazy var statusBarController = StatusBarController(viewModel: viewModel)

    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource: DispatchSourceSignal?
    private var powerOffObserver: NSObjectProtocol?
    private var activeAppObserver: NSObjectProtocol?
    private var testSpeakTimeoutWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.setup()
        AppLog.write("APP", "G9N9N-Vibe \(AppStorage.appVersionString) 启动")

        LaunchAtLogin.repairIfStale()
        setupMainMenu()
        setupSignalSafetyNet()
        wireSubsystems()

        // 1. 检测驱动状态并执行启动崩溃自愈（若上次强杀残留虚拟默认麦，立即无损还原）
        let driverReady = DriverManager.shared.isDriverActiveInCoreAudio
        viewModel.driverInstalled = driverReady
        if !driverReady && viewModel.micPolicy.requiresDriver {
            viewModel.micPolicy = .macOnly
            AppStorage.micPolicy = .macOnly
        }
        MicRouteCoordinator.recoverIfNeeded(
            driverAvailable: driverReady,
            policy: viewModel.micPolicy,
            method: viewModel.voiceInputMethod
        )
        MicRouteCoordinator.apply(
            driverAvailable: driverReady,
            policy: viewModel.micPolicy,
            method: viewModel.voiceInputMethod
        )
        AudioPipe.shared.rebuildAfterDriverChange(driverAvailable: driverReady, policy: viewModel.micPolicy)

        // 2. 启动核心硬件与监控子系统
        DriverManager.shared.startObservingHardwareChanges()
        setupFrontmostAppObserver()
        sessionCoordinator.start()
        keyboardMonitor.start()
        hidBridge.start()
        bleBridge.start()

        viewModel.refreshPermissions()
        viewModel.launchAtLogin = LaunchAtLogin.isEnabled
        // 首次打开直接展示主控制台，并在首次安装时自动弹出 3 步友好引导弹窗
        mainWindowController.showWindow()
        if !AppStorage.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.viewModel.showOnboarding = true
            }
        }
        // 检测是否刚刚完成版本升级，若是则立即展示明显的翠绿升级成功横幅与 4.5 秒 Toast 确认
        let currentVersion = AppStorage.appVersionString
        if let previousVersion = AppStorage.lastLaunchedVersion,
           AppUpdater.isVersion(currentVersion, newerThan: previousVersion) {
            viewModel.upgradedBannerInfo = (from: previousVersion, to: currentVersion)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                self.viewModel.showToast(
                    self.viewModel.t("✓ 已成功升级至 G9NVibe v\(currentVersion)", "✓ Successfully updated to G9NVibe v\(currentVersion)"),
                    positive: true,
                    duration: 4.5
                )
            }
            AppLog.write("UPDATE", "检测到版本已升级：v\(previousVersion) -> v\(currentVersion)")
        }
        AppStorage.lastLaunchedVersion = currentVersion

        // 启动 4 秒后按需静默检查更新（每 24 小时最多一次，零打扰）
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            AppUpdater.shared.checkSilentlyIfDue()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 用户从系统设置授权返回后，自动刷新权限状态、补启键盘触发监听并同步电平预览
        viewModel.refreshPermissions()
        keyboardMonitor.start()
        syncPreviewMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        performSafeShutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 点击窗口左上角关闭按钮（×）时仅隐藏页面并释放视图内存，程序继续常驻后台与 Dock 栏
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 点击 Dock 图标立即重新唤起主控制台
        mainWindowController.showWindow()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "打开 G9NVibe 控制台", action: #selector(handleDockOpenConsole), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let testItem = NSMenuItem(title: "触发试说测试", action: #selector(handleDockTestSpeak), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)
        return menu
    }

    @objc private func handleDockOpenConsole() {
        mainWindowController.showWindow()
    }

    @objc private func handleDockTestSpeak() {
        toggleTestSpeak()
    }

    @objc private func handleCheckUpdatesMenu() {
        mainWindowController.showWindow()
        viewModel.openUpdateDialog()
    }

    /// 切换主界面「触发试说测试」：仅在测试/录音期间启动采麦与光柱动效，停止或超时后立即归零熄灯
    private func toggleTestSpeak() {
        if viewModel.isTestSpeaking {
            stopTestSpeak(sendStopShortcut: true)
            return
        }
        if viewModel.isAllMicsClosed {
            viewModel.showToast(
                viewModel.t("双麦已关闭，请先点击「仅电脑麦」或恢复麦克风后再试说", "Mics are muted. Enable a microphone before testing."),
                positive: false
            )
            return
        }
        testSpeakTimeoutWork?.cancel()
        viewModel.isTestSpeaking = true
        viewModel.triggerRemoteLedPulse()
        syncPreviewMonitoring()
        AudioPipe.shared.setSessionActive(true, triggerSource: .keyboard)
        statusBarController.updateIconState(isRecording: true, isRemoteSource: false)
        InputTrigger.beginRecognition()

        // 25 秒安全兜底自动收尾，防止用户忘记手动点「停止试说测试」导致持续占用麦克风
        let timeout = DispatchWorkItem { [weak self] in
            self?.stopTestSpeak(sendStopShortcut: true)
        }
        testSpeakTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 25.0, execute: timeout)
    }

    private func stopTestSpeak(sendStopShortcut: Bool) {
        testSpeakTimeoutWork?.cancel()
        testSpeakTimeoutWork = nil
        guard viewModel.isTestSpeaking else { return }
        viewModel.isTestSpeaking = false
        if sendStopShortcut {
            InputTrigger.endRecognition()
        }
        if !viewModel.isRecording {
            AudioPipe.shared.setSessionActive(false, triggerSource: .none)
            statusBarController.updateIconState(isRecording: false, isRemoteSource: false)
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: "G9NVibe")
        let openItem = NSMenuItem(title: "打开控制台", action: #selector(handleDockOpenConsole), keyEquivalent: "o")
        openItem.target = self
        appMenu.addItem(openItem)
        let updateItem = NSMenuItem(title: "检查更新…", action: #selector(handleCheckUpdatesMenu), keyEquivalent: "u")
        updateItem.target = self
        appMenu.addItem(updateItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "关闭窗口（保持后台运行）", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(NSMenuItem(title: "隐藏 G9NVibe", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "退出 G9NVibe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }

    private func performSafeShutdown() {
        AppLog.write("APP", "执行安全退出与硬件/路由还原")
        if let activeAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeAppObserver)
            self.activeAppObserver = nil
        }
        sessionCoordinator.stopAndReleaseAll()
        InputTrigger.releaseHeldTrigger()
        AppSwitcherSession.shared.commit()
        keyboardMonitor.stop()
        hidBridge.stop()
        bleBridge.stop()
        audioStateMonitor.stop()
        AudioPipe.shared.shutdown()
        MicRouteCoordinator.restoreOriginalInputDevice(force: false)
    }

    private func setupSignalSafetyNet() {
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in
            self?.performSafeShutdown()
            NSApp.terminate(nil)
        }
        term.resume()
        sigtermSource = term

        signal(SIGINT, SIG_IGN)
        let intr = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intr.setEventHandler { [weak self] in
            self?.performSafeShutdown()
            NSApp.terminate(nil)
        }
        intr.resume()
        sigintSource = intr

        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.performSafeShutdown()
        }
    }

    /// 监听 macOS 前台切换应用（原生事件零耗电），开启「自动切预设」时在编程 IDE 与办公/媒体应用间无缝切换键位
    private func setupFrontmostAppObserver() {
        activeAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, self.mappingStore.autoSwitchByApp else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard let targetPreset = RemoteMappingPreset.recommendedPreset(
                forBundleID: app.bundleIdentifier,
                customCodingBundleIDs: self.mappingStore.customCodingBundleIDSet
            ) else { return }
            if self.mappingStore.activePreset != targetPreset {
                self.mappingStore.applyPreset(targetPreset)
                AppLog.write("MAPPING", "随前台应用 \(app.localizedName ?? app.bundleIdentifier ?? "") 自动切至 \(targetPreset.title)")
            }
            self.viewModel.autoSwitchedAppName = app.localizedName
        }
    }

    private func wireSubsystems() {
        // 菜单栏
        statusBarController.onOpenMainWindow = { [weak self] in
            self?.mainWindowController.showWindow()
        }
        statusBarController.onCheckUpdatesRequested = { [weak self] in
            self?.mainWindowController.showWindow()
            self?.viewModel.openUpdateDialog()
        }
        statusBarController.onQuitRequested = {
            NSApp.terminate(nil)
        }

        // 主窗口开关生命周期：关窗即解绑实时电平回调，实现极低后台占用
        mainWindowController.onVisibilityChanged = { [weak self] visible in
            self?.bindLevelMeters(enabled: visible)
        }

        // BLE ATVV 桥接（控制面/音频面解耦）
        bleBridge.shouldConsumeRemoteAudio = {
            AudioPipe.shared.shouldAcceptRemoteAudio()
        }
        bleBridge.onDecodedSamples = { samples, rate in
            AudioPipe.shared.feedRemote(samples: samples, inputSampleRate: rate)
        }
        bleBridge.onConnectionChanged = { [weak self] connected in
            self?.viewModel.bleConnected = connected
            if !connected {
                self?.viewModel.remoteBatteryLevel = nil
            }
        }
        bleBridge.onBatteryLevelChanged = { [weak self] level in
            self?.viewModel.remoteBatteryLevel = level
        }
        bleBridge.onBluetoothAuthorizationChanged = { [weak self] _ in
            self?.viewModel.refreshPermissions()
        }
        bleBridge.onAudioStarted = { [weak self] reason, _ in
            self?.viewModel.voiceKeyLivePulse = true
            self?.viewModel.triggerRemoteLedPulse()
            self?.sessionCoordinator.remoteAudioStarted(reason: reason)
        }
        bleBridge.onAudioStopped = { [weak self] reason in
            self?.viewModel.voiceKeyLivePulse = false
            self?.sessionCoordinator.remoteAudioStopped(reason: reason)
        }

        // HID 14 键桥接
        hidBridge.onConnectionChanged = { [weak self] connected in
            self?.viewModel.hidConnected = connected
        }
        hidBridge.onButtonPressedFeedback = { [weak self] buttonID, isDown in
            guard let self, isDown, self.mainWindowController.isVisible else { return }
            DispatchQueue.main.async {
                self.viewModel.selectedButtonID = buttonID
                self.viewModel.triggerRemoteLedPulse()
            }
        }
        hidBridge.onSwapMicRequested = { [weak self] in
            self?.cycleMicrophonePolicyFromRemote()
        }

        // 物理键盘触发监听（驱动「智能随动」）
        keyboardMonitor.onPhysicalTriggerDown = { [weak self] in
            self?.sessionCoordinator.physicalKeyboardTriggerDown()
        }
        keyboardMonitor.onPhysicalTriggerUp = { [weak self] in
            self?.sessionCoordinator.physicalKeyboardTriggerUp()
        }

        // 会话状态机联动
        sessionCoordinator.onRequestOpenRemoteMic = { [weak self] in
            self?.bleBridge.openMicrophone() ?? .unavailable
        }
        sessionCoordinator.onRequestCloseRemoteMic = { [weak self] in
            self?.bleBridge.closeMicrophone()
        }
        sessionCoordinator.onStatusChanged = { [weak self] text, src, active in
            guard let self else { return }
            if !active && self.viewModel.isTestSpeaking {
                // 若外部输入法或快捷键主动结束了会话，同步收尾试说测试按钮状态
                self.stopTestSpeak(sendStopShortcut: false)
            }
            // 按需短切系统默认麦：仅在遥控器收音会话激活瞬间切入虚拟麦，结束瞬间立即还原，待机永不接管系统麦
            if active && !self.viewModel.allMuted {
                MicRouteCoordinator.beginTransientVirtualRoute(
                    driverAvailable: self.viewModel.driverInstalled,
                    policy: self.viewModel.micPolicy,
                    method: self.viewModel.voiceInputMethod,
                    source: src
                )
            } else {
                MicRouteCoordinator.endTransientVirtualRoute()
            }
            self.viewModel.sessionStatusText = text
            self.viewModel.activeTriggerSource = src
            self.viewModel.isRecording = active
            let isRemote = (src == .remote) && self.viewModel.driverInstalled && self.viewModel.micPolicy != .macOnly
            self.statusBarController.updateIconState(isRecording: active, isRemoteSource: isRemote)
            // AudioRouteDoctor：检测豆包选错物理麦的“哑巴陷阱”，在界面体检卡温和提示，不弹桌面遮挡条
            if active && self.viewModel.driverInstalled && self.viewModel.micPolicy != .macOnly && self.viewModel.voiceInputMethod == .doubao {
                let snap = self.audioStateMonitor.snapshotNow()
                self.viewModel.doubaoRouteMismatch = (snap.captureObservable && snap.isRecording && !snap.isUsingVirtualMic)
            }
        }

        // 驱动热变化监听
        DriverManager.shared.onDriverAvailabilityChanged = { [weak self] available in
            guard let self else { return }
            if self.viewModel.driverInstalled != available {
                self.viewModel.driverInstalled = available
                if !available {
                    self.viewModel.doubaoRouteMismatch = false
                    if self.viewModel.micPolicy.requiresDriver {
                        self.viewModel.micPolicy = .macOnly
                        AppStorage.micPolicy = .macOnly
                    }
                    // 驱动态切回免驱态时同步双麦静音状态，防止 AudioPipe 残留 allMuted 锁死
                    if self.viewModel.allMuted {
                        self.viewModel.macMonitoringEnabled = false
                        self.viewModel.allMuted = false
                    }
                    AudioPipe.shared.setAllMuted(!self.viewModel.macMonitoringEnabled)
                }
                AudioPipe.shared.rebuildAfterDriverChange(driverAvailable: available, policy: self.viewModel.micPolicy)
                MicRouteCoordinator.apply(driverAvailable: available, policy: self.viewModel.micPolicy, method: self.viewModel.voiceInputMethod)
                self.bindLevelMeters(enabled: self.mainWindowController.isVisible)
            }
        }

        // ViewModel 交互回调
        viewModel.onPolicyChanged = { [weak self] policy in
            guard let self else { return }
            self.sessionCoordinator.stopAndReleaseAll()
            AudioPipe.shared.updatePolicy(policy)
            MicRouteCoordinator.apply(
                driverAvailable: self.viewModel.driverInstalled,
                policy: policy,
                method: self.viewModel.voiceInputMethod
            )
            AppLog.write("AUDIO", "已切换收音模式：\(policy.title)")
        }

        viewModel.onInputMethodChanged = { [weak self] method in
            guard let self else { return }
            self.audioStateMonitor.targetDidChange()
            MicRouteCoordinator.apply(
                driverAvailable: self.viewModel.driverInstalled,
                policy: self.viewModel.micPolicy,
                method: method
            )
        }

        viewModel.onTriggerShortcutChanged = { shortcut in
            InputTrigger.releaseHeldTrigger()
            AppLog.write("TRIGGER", "语音触发键已设为：\(shortcut.label)")
        }

        viewModel.onTriggerModeChanged = { _ in
            InputTrigger.releaseHeldTrigger()
        }

        viewModel.onMappingEnabledChanged = { [weak self] enabled in
            self?.hidBridge.setRemappingEnabled(enabled)
        }

        viewModel.onRequestInstallDriver = { [weak self] desiredPolicy in
            self?.installDriverFlow(desiredPolicy: desiredPolicy)
        }

        viewModel.onRequestUninstallDriver = { [weak self] in
            self?.uninstallDriverFlow()
        }

        viewModel.onTestSpeakRequested = { [weak self] in
            self?.toggleTestSpeak()
        }

        viewModel.onPageChanged = { [weak self] _ in
            self?.syncPreviewMonitoring()
        }

        viewModel.onMacMonitoringToggled = { [weak self] enabled in
            guard let self else { return }
            if !enabled {
                self.stopTestSpeak(sendStopShortcut: true)
                self.sessionCoordinator.stopAndReleaseAll()
                MicRouteCoordinator.endTransientVirtualRoute()
            }
            if !self.viewModel.driverInstalled {
                AudioPipe.shared.setAllMuted(!enabled)
            }
            self.syncPreviewMonitoring()
        }

        viewModel.onAllMutedChanged = { [weak self] muted in
            guard let self else { return }
            if muted {
                self.stopTestSpeak(sendStopShortcut: true)
                self.sessionCoordinator.stopAndReleaseAll()
                MicRouteCoordinator.endTransientVirtualRoute()
            }
            AudioPipe.shared.setAllMuted(muted)
            self.syncPreviewMonitoring()
            AppLog.write("AUDIO", muted ? "双麦已全部暂停，系统默认麦保持原物理麦未接管" : "已恢复麦克风收音路由")
        }

        viewModel.onRemoteGainChanged = { [weak self] preset in
            self?.bleBridge.remoteGain = preset.linearGain
            AudioPipe.shared.setRemoteGainPreset(preset)
        }

        // 原生自动更新引擎联动
        AppUpdater.shared.onStateChanged = { [weak self] state in
            guard let self else { return }
            let previous = self.viewModel.updateState
            self.viewModel.updateState = state
            if case .available(let info) = state, !previous.hasAvailableUpdate, !self.viewModel.showUpdateSheet {
                self.viewModel.showToast(self.viewModel.t(
                    "发现新版本 \(info.tagName)，点击左上角版本徽标即可一键更新",
                    "Update \(info.tagName) available — click version badge to install"
                ))
            }
        }
        AppUpdater.shared.onWillTerminateForUpdate = { [weak self] in
            self?.performSafeShutdown()
        }
    }

    private func syncPreviewMonitoring() {
        let shouldPreview = mainWindowController.isVisible &&
            viewModel.currentPage == .audio &&
            viewModel.isMacEnabled
        AudioPipe.shared.setUIPreviewEnabled(shouldPreview)
    }

    private func bindLevelMeters(enabled: Bool) {
        if enabled {
            AudioPipe.shared.onMacLevel = { [weak self] db in self?.viewModel.macLevelDb = db }
            AudioPipe.shared.onOutputLevel = { [weak self] db in self?.viewModel.outputLevelDb = db }
            bleBridge.onLevel = { [weak self] db in self?.viewModel.remoteLevelDb = db }
            syncPreviewMonitoring()
        } else {
            stopTestSpeak(sendStopShortcut: true)
            AudioPipe.shared.setUIPreviewEnabled(false)
            AudioPipe.shared.onMacLevel = nil
            AudioPipe.shared.onOutputLevel = nil
            bleBridge.onLevel = nil
            viewModel.macLevelDb = -120
            viewModel.outputLevelDb = -120
            viewModel.remoteLevelDb = -120
        }
    }

    private func cycleMicrophonePolicyFromRemote() {
        guard viewModel.driverInstalled else { return }
        let order: [MicRoutingPolicy] = [.smartByTriggerSource, .macOnly, .remoteOnly, .dualMix]
        let idx = order.firstIndex(of: viewModel.micPolicy) ?? 0
        let next = order[(idx + 1) % order.count]
        viewModel.selectPolicy(next)
    }

    private func installDriverFlow(desiredPolicy: MicRoutingPolicy) {
        guard !viewModel.isDriverBusy else { return }
        viewModel.isDriverBusy = true
        stopTestSpeak(sendStopShortcut: true)
        sessionCoordinator.stopAndReleaseAll()
        AudioPipe.shared.shutdown()

        DriverManager.shared.installBundledDriver { [weak self] result in
            guard let self else { return }
            self.viewModel.isDriverBusy = false
            switch result {
            case .success:
                self.viewModel.driverInstalled = true
                self.viewModel.allMuted = false
                self.viewModel.macMonitoringEnabled = true
                AudioPipe.shared.setAllMuted(false)
                self.audioStateMonitor.rebuildAfterAudioDaemonRestart()
                self.viewModel.selectPolicy(desiredPolicy)
                AudioPipe.shared.rebuildAfterDriverChange(driverAvailable: true, policy: self.viewModel.micPolicy)
                self.bindLevelMeters(enabled: self.mainWindowController.isVisible)
                self.viewModel.showToast(self.viewModel.t("✓ 内置音频驱动已启用，双麦就绪", "✓ Built-in audio driver enabled"))
                AppLog.write("DRIVER", "G9N9N-Vibe Mic 驱动已热重载就绪")
            case .failure(let error):
                AudioPipe.shared.rebuildAfterDriverChange(driverAvailable: false, policy: .macOnly)
                AudioPipe.shared.setAllMuted(self.viewModel.isAllMicsClosed)
                self.bindLevelMeters(enabled: self.mainWindowController.isVisible)
                self.viewModel.sessionStatusText = "驱动未启用"
                self.viewModel.showToast(self.viewModel.t("已取消启用遥控器声卡（继续仅使用电脑麦）", "Driver setup canceled (Mac mic only)"), positive: false)
                AppLog.write("DRIVER", "驱动未启用：\(error.localizedDescription)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self, !self.viewModel.isRecording, self.viewModel.sessionStatusText == "驱动未启用" else { return }
                    self.viewModel.sessionStatusText = "等待录音"
                }
            }
        }
    }

    private func uninstallDriverFlow() {
        guard !viewModel.isDriverBusy else { return }
        viewModel.isDriverBusy = true
        stopTestSpeak(sendStopShortcut: true)
        sessionCoordinator.stopAndReleaseAll()
        AudioPipe.shared.shutdown()

        DriverManager.shared.uninstallDriver { [weak self] result in
            guard let self else { return }
            self.viewModel.isDriverBusy = false
            switch result {
            case .success:
                self.viewModel.driverInstalled = false
                self.viewModel.doubaoRouteMismatch = false
                self.viewModel.allMuted = false
                self.viewModel.macMonitoringEnabled = true
                self.viewModel.micPolicy = .macOnly
                AppStorage.micPolicy = .macOnly
                AudioPipe.shared.setAllMuted(false)
                self.audioStateMonitor.rebuildAfterAudioDaemonRestart()
                AudioPipe.shared.rebuildAfterDriverChange(driverAvailable: false, policy: .macOnly)
                self.bindLevelMeters(enabled: self.mainWindowController.isVisible)
                self.viewModel.showToast(self.viewModel.t("✓ 已卸载遥控器声卡，恢复仅电脑麦直通", "✓ Driver uninstalled, back to Mac mic direct"))
                AppLog.write("DRIVER", "已无痕卸载驱动，恢复纯免驱模式")
            case .failure(let error):
                // 用户取消卸载时必须重建此前 shutdown() 销毁的虚拟声卡输出句柄，避免后续无声
                AudioPipe.shared.rebuildAfterDriverChange(driverAvailable: self.viewModel.driverInstalled, policy: self.viewModel.micPolicy)
                AudioPipe.shared.setAllMuted(self.viewModel.isAllMicsClosed)
                self.bindLevelMeters(enabled: self.mainWindowController.isVisible)
                self.viewModel.showToast(self.viewModel.t("已取消卸载驱动", "Driver uninstall canceled"), positive: false)
                AppLog.write("DRIVER", "卸载取消：\(error.localizedDescription)")
            }
        }
    }
}

// MARK: - 程序入口（支持 DEBUG 自动化状态机自测参数）

#if DEBUG
if CommandLine.arguments.contains("--voice-session-self-test") {
    VoiceSessionSelfTest.runAll()
    exit(0)
}
#endif

let app = NSApplication.shared
// Dock 栏常驻模式（关闭主窗口仅隐藏页面释放内存，右键 Dock「退出」或 ⌘Q 才彻底退出）
app.setActivationPolicy(.regular)
let controller = AppController()
app.delegate = controller
app.run()
