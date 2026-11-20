import AppKit
import Foundation

// MARK: - 自动化状态机与业务逻辑自测入口

#if DEBUG
if CommandLine.arguments.contains("--voice-session-self-test") {
    VoiceSessionSelfTest.runAll()
    exit(0)
}
#endif

// MARK: - G9NVibe 单进程架构主控制器（极致精炼常驻底座 + 关窗即彻底析构视图树）

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
        AppLog.write("APP", "G9NVibe \(AppStorage.appVersionString) 启动 (PID: \(ProcessInfo.processInfo.processIdentifier))")

        // 0. 单实例单进程守护与升级重启交接
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? "io.github.g9n9n-vibe"

        // 若是从更新升级重启而来，坚决清除被替换的旧进程 PID，绝不被旧进程反杀
        var ignoredPID: pid_t = 0
        if let idx = CommandLine.arguments.firstIndex(of: "--restarted-from-update"),
           idx + 1 < CommandLine.arguments.count,
           let oldPID = Int32(CommandLine.arguments[idx + 1]) {
            ignoredPID = oldPID
            if oldPID != currentPID {
                kill(oldPID, SIGKILL)
                usleep(50_000)
            }
        }

        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let otherInstances = runningApps.filter { $0.processIdentifier != currentPID && $0.processIdentifier != ignoredPID }
        if let existing = otherInstances.first {
            AppLog.write("APP", "检测到已有 G9NVibe 实例在运行 (PID: \(existing.processIdentifier))，激活已有窗口并退出当前冗余进程")
            existing.activate(options: [.activateIgnoringOtherApps])
            exit(0)
        }

        LaunchAtLogin.repairIfStale()
        setupMainMenu()
        setupSignalSafetyNet()
        wireSubsystems()

        // 1. 检测驱动状态并执行启动自愈
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

        // 3. 打开主控制台界面
        mainWindowController.showWindow()

        // 首次打开引导
        if !AppStorage.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.viewModel.showOnboarding = true
            }
        }

        // 升级确认提示
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

        // 启动 4 秒后按需静默检查更新
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            AppUpdater.shared.checkSilentlyIfDue()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        viewModel.refreshPermissions()
        keyboardMonitor.start()
        syncPreviewMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        performSafeShutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 单进程架构：关窗不退出进程，保持 Dock 栏图标与遥控器蓝牙常驻
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 点击 Dock 图标立即重新唤起主控制台！
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

        // BLE ATVV 桥接
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

        // 物理键盘触发监听
        keyboardMonitor.onPhysicalTriggerDown = { [weak self] in
            self?.sessionCoordinator.physicalKeyboardTriggerDown()
        }
        keyboardMonitor.onPhysicalTriggerUp = { [weak self] in
            self?.sessionCoordinator.physicalKeyboardTriggerUp()
        }

        // 会话状态机联动
        sessionCoordinator.onRequestOpenRemoteMic = { [weak self] bypassDebounce in
            self?.bleBridge.openMicrophone(bypassDebounce: bypassDebounce) ?? .unavailable
        }
        sessionCoordinator.onRequestCloseRemoteMic = { [weak self] in
            self?.bleBridge.closeMicrophone()
        }
        sessionCoordinator.onStatusChanged = { [weak self] text, src, active in
            guard let self else { return }
            if !active && self.viewModel.isTestSpeaking {
                self.stopTestSpeak(sendStopShortcut: false)
            }
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
            // 关窗退后台核心熔断：强制收敛所有录音会话，物理麦瞬关，系统橙色麦克风图标 0ms 熄灭
            stopTestSpeak(sendStopShortcut: true)
            sessionCoordinator.stopAndReleaseAll()
            AudioPipe.shared.setSessionActive(false, triggerSource: .none)
            AudioPipe.shared.setUIPreviewEnabled(false)
            AudioPipe.shared.onMacLevel = nil
            AudioPipe.shared.onOutputLevel = nil
            bleBridge.onLevel = nil
            viewModel.macLevelDb = -120
            viewModel.outputLevelDb = -120
            viewModel.remoteLevelDb = -120

            // 深度内存清理：强制内核分配器与 XNU 内核归还所有脏页
            MemoryReclaim.performDeepPurge()
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
                AudioPipe.shared.rebuildAfterDriverChange(driverAvailable: self.viewModel.driverInstalled, policy: self.viewModel.micPolicy)
                AudioPipe.shared.setAllMuted(self.viewModel.isAllMicsClosed)
                self.bindLevelMeters(enabled: self.mainWindowController.isVisible)
                self.viewModel.showToast(self.viewModel.t("已取消卸载驱动", "Driver uninstall canceled"), positive: false)
                AppLog.write("DRIVER", "卸载取消：\(error.localizedDescription)")
            }
        }
    }
}

// MARK: - 程序入口

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = AppController()
app.delegate = controller
app.run()
