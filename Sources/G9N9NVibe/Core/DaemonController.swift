import AppKit
import Foundation

/// G9NDaemon 后台硬件守护引擎：
/// 负责蓝牙 BLE、HID 14 键桥接、物理热键监听、音频路由、虚拟驱动管理与 IPC 服务端。
/// 零 SwiftUI / 零 Metal / 零辅助渲染服务，长期常驻内存稳定在 6MB ~ 8MB！
final class DaemonController: NSObject {
    private let mappingStore = RemoteMappingStore.shared
    private let bleBridge = BLEBridge()
    private let hidBridge = G9N9NHIDBridge()
    private let keyboardMonitor = KeyboardTapMonitor()
    private let audioStateMonitor = AudioStateMonitor()
    private lazy var sessionCoordinator = VoiceSessionCoordinator(audioState: audioStateMonitor)
    private let ipcServer = VibeIPCServer()
    private let statusBar = DaemonStatusBarController()

    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource: DispatchSourceSignal?
    private var activeAppObserver: NSObjectProtocol?
    private var testSpeakTimeoutWork: DispatchWorkItem?

    // 守护引擎内部状态
    private var bleConnected: Bool = false
    private var hidConnected: Bool = false
    private var remoteBatteryLevel: Int? = nil
    private var driverInstalled: Bool = false
    private var micPolicy: MicRoutingPolicy = AppStorage.micPolicy
    private var voiceInputMethod: VoiceInputMethod = VoiceInputMethod.current
    private var voiceTriggerShortcut: VoiceTriggerShortcut = AppStorage.voiceTriggerShortcut
    private var triggerMode: InputTriggerMode = AppStorage.inputTriggerMode
    private var isRecording: Bool = false
    private var isTestSpeaking: Bool = false
    private var allMuted: Bool = false
    private var isMacEnabled: Bool = true
    private var remoteGainPreset: RemoteMicGainPreset = AppStorage.remoteMicGainPreset
    private var sessionStatusText: String = "等待录音"
    private var activeTriggerSource: SessionTriggerSource = .none
    private var doubaoRouteMismatch: Bool = false
    private var hasSubscribedLevels: Bool = false

    func start() {
        AppLog.setup()
        AppLog.write("DAEMON", "G9NDaemon 后台硬件守护引擎启动 (PID: \(ProcessInfo.processInfo.processIdentifier))")

        setupSignalSafetyNet()
        wireSubsystems()

        // 1. 检测驱动状态并执行启动自愈
        driverInstalled = DriverManager.shared.isDriverActiveInCoreAudio
        if !driverInstalled && micPolicy.requiresDriver {
            micPolicy = .macOnly
            AppStorage.micPolicy = .macOnly
        }
        MicRouteCoordinator.recoverIfNeeded(
            driverAvailable: driverInstalled,
            policy: micPolicy,
            method: voiceInputMethod
        )
        MicRouteCoordinator.apply(
            driverAvailable: driverInstalled,
            policy: micPolicy,
            method: voiceInputMethod
        )
        AudioPipe.shared.rebuildAfterDriverChange(driverAvailable: driverInstalled, policy: micPolicy)

        // 2. 启动硬件与监控子系统
        DriverManager.shared.startObservingHardwareChanges()
        setupFrontmostAppObserver()
        sessionCoordinator.start()
        keyboardMonitor.start()
        hidBridge.start()
        bleBridge.start()

        // 3. 启动本地 IPC 服务端
        let ipcOk = ipcServer.start()
        AppLog.write("DAEMON", ipcOk ? "IPC 服务端启动就绪: \(VibeIPCConstants.socketPath)" : "IPC 服务端启动失败")

        // 4. 初始化状态栏
        updateStatusBar()

        // 5. 执行一次启动期空闲堆块回退
        _ = malloc_zone_pressure_relief(nil, 0)

        // 6. 测量并打印当前守护引擎真实物理内存 Footprint
        let memMB = Self.currentPhysFootprintMB()
        print("[DAEMON-METRIC] G9NDaemon 常驻物理内存 Footprint: \(String(format: "%.2f", memMB)) MB")
        AppLog.write("DAEMON", "常驻物理内存 Footprint: \(String(format: "%.2f", memMB)) MB")

        // 0.8秒后再次压降并采样稳态内存
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            _ = malloc_zone_pressure_relief(nil, 0)
            let steadyMB = Self.currentPhysFootprintMB()
            print("[DAEMON-METRIC] G9NDaemon 稳态常驻物理内存 Footprint: \(String(format: "%.2f", steadyMB)) MB")
        }

        // 7. 静默更新检测
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            AppUpdater.shared.checkSilentlyIfDue()
        }
    }

    /// 通过 XNU 内核 TASK_VM_INFO 精准获取当前物理常驻 Footprint (MB)
    static func currentPhysFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / (1024.0 * 1024.0)
    }

    private func makeSnapshot() -> DaemonStateSnapshot {
        DaemonStateSnapshot(
            bleConnected: bleConnected,
            hidConnected: hidConnected,
            remoteBatteryLevel: remoteBatteryLevel,
            driverInstalled: driverInstalled,
            micPolicy: micPolicy,
            voiceInputMethod: voiceInputMethod,
            voiceTriggerShortcut: voiceTriggerShortcut,
            triggerMode: triggerMode,
            isRecording: isRecording,
            isTestSpeaking: isTestSpeaking,
            allMuted: allMuted,
            isMacEnabled: isMacEnabled,
            remoteGainPreset: remoteGainPreset,
            sessionStatusText: sessionStatusText,
            activeTriggerSource: activeTriggerSource,
            doubaoRouteMismatch: doubaoRouteMismatch,
            appVersion: AppStorage.appVersionString
        )
    }

    private func broadcastState() {
        ipcServer.broadcast(.stateSnapshot(makeSnapshot()))
        updateStatusBar()
    }

    private func updateStatusBar() {
        let isRemote = (activeTriggerSource == .remote) && driverInstalled && micPolicy != .macOnly
        statusBar.updateState(
            policy: micPolicy,
            driverInstalled: driverInstalled,
            allMuted: allMuted,
            battery: remoteBatteryLevel,
            isRecording: isRecording,
            isRemoteSource: isRemote
        )
    }

    private func wireSubsystems() {
        // IPC 消息处理
        ipcServer.onClientConnected = { [weak self] clientFd in
            guard let self else { return }
            AppLog.write("DAEMON", "前台控制台已连接 (FD: \(clientFd))，立即推送状态快照")
            self.ipcServer.send(.stateSnapshot(self.makeSnapshot()), to: clientFd)
        }

        ipcServer.onClientDisconnected = { [weak self] clientFd in
            AppLog.write("DAEMON", "前台控制台已断开 (FD: \(clientFd))")
            self?.hasSubscribedLevels = false
            self?.syncAudioPipeCallbacks()
        }

        ipcServer.onMessageReceived = { [weak self] msg, clientFd in
            self?.handleIPCMessage(msg, from: clientFd)
        }

        // 状态栏菜单栏操作
        statusBar.onOpenConsoleRequested = { [weak self] in
            self?.launchOrActivateConsole()
        }
        statusBar.onPolicyChanged = { [weak self] p in
            self?.applyPolicy(p)
        }
        statusBar.onToggleMuteAllRequested = { [weak self] in
            self?.toggleMuteAll()
        }
        statusBar.onCheckUpdatesRequested = { [weak self] in
            self?.launchOrActivateConsole()
        }
        statusBar.onQuitDaemonRequested = { [weak self] in
            self?.performSafeShutdown()
            exit(0)
        }

        // BLE ATVV 桥接
        bleBridge.shouldConsumeRemoteAudio = {
            AudioPipe.shared.shouldAcceptRemoteAudio()
        }
        bleBridge.onDecodedSamples = { samples, rate in
            AudioPipe.shared.feedRemote(samples: samples, inputSampleRate: rate)
        }
        bleBridge.onConnectionChanged = { [weak self] connected in
            guard let self else { return }
            self.bleConnected = connected
            if !connected { self.remoteBatteryLevel = nil }
            self.broadcastState()
        }
        bleBridge.onBatteryLevelChanged = { [weak self] level in
            guard let self else { return }
            self.remoteBatteryLevel = level
            self.broadcastState()
        }
        bleBridge.onAudioStarted = { [weak self] reason, _ in
            self?.sessionCoordinator.remoteAudioStarted(reason: reason)
        }
        bleBridge.onAudioStopped = { [weak self] reason in
            self?.sessionCoordinator.remoteAudioStopped(reason: reason)
        }

        // HID 14 键桥接
        hidBridge.onConnectionChanged = { [weak self] connected in
            guard let self else { return }
            self.hidConnected = connected
            self.broadcastState()
        }
        hidBridge.onButtonPressedFeedback = { [weak self] buttonID, isDown in
            guard let self else { return }
            self.ipcServer.broadcast(.buttonPressed(buttonID: buttonID, isDown: isDown))
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
        sessionCoordinator.onRequestOpenRemoteMic = { [weak self] in
            self?.bleBridge.openMicrophone() ?? .unavailable
        }
        sessionCoordinator.onRequestCloseRemoteMic = { [weak self] in
            self?.bleBridge.closeMicrophone()
        }
        sessionCoordinator.onStatusChanged = { [weak self] text, src, active in
            guard let self else { return }
            if !active && self.isTestSpeaking {
                self.stopTestSpeak(sendStopShortcut: false)
            }
            if active && !self.allMuted {
                MicRouteCoordinator.beginTransientVirtualRoute(
                    driverAvailable: self.driverInstalled,
                    policy: self.micPolicy,
                    method: self.voiceInputMethod,
                    source: src
                )
            } else {
                MicRouteCoordinator.endTransientVirtualRoute()
            }
            self.sessionStatusText = text
            self.activeTriggerSource = src
            self.isRecording = active
            if active && self.driverInstalled && self.micPolicy != .macOnly && self.voiceInputMethod == .doubao {
                let snap = self.audioStateMonitor.snapshotNow()
                self.doubaoRouteMismatch = (snap.captureObservable && snap.isRecording && !snap.isUsingVirtualMic)
            }
            self.broadcastState()
        }

        // 驱动热插拔变化
        DriverManager.shared.onDriverAvailabilityChanged = { [weak self] available in
            guard let self else { return }
            if self.driverInstalled != available {
                self.driverInstalled = available
                if !available {
                    self.doubaoRouteMismatch = false
                    if self.micPolicy.requiresDriver {
                        self.micPolicy = .macOnly
                        AppStorage.micPolicy = .macOnly
                    }
                    if self.allMuted {
                        self.isMacEnabled = false
                        self.allMuted = false
                    }
                    AudioPipe.shared.setAllMuted(!self.isMacEnabled)
                }
                AudioPipe.shared.rebuildAfterDriverChange(driverAvailable: available, policy: self.micPolicy)
                MicRouteCoordinator.apply(driverAvailable: available, policy: self.micPolicy, method: self.voiceInputMethod)
                self.broadcastState()
            }
        }
    }

    private func handleIPCMessage(_ msg: IPCMessage, from clientFd: Int32) {
        switch msg {
        case .getState:
            ipcServer.send(.stateSnapshot(makeSnapshot()), to: clientFd)

        case .setPolicy(let policy):
            applyPolicy(policy)

        case .setInputMethod(let method):
            self.voiceInputMethod = method
            VoiceInputMethod.select(method)
            audioStateMonitor.targetDidChange()
            MicRouteCoordinator.apply(driverAvailable: driverInstalled, policy: micPolicy, method: method)
            broadcastState()

        case .setTriggerShortcut(let shortcut):
            self.voiceTriggerShortcut = shortcut
            AppStorage.voiceTriggerShortcut = shortcut
            InputTrigger.releaseHeldTrigger()
            broadcastState()

        case .setTriggerMode(let mode):
            self.triggerMode = mode
            AppStorage.inputTriggerMode = mode
            InputTrigger.releaseHeldTrigger()
            broadcastState()

        case .toggleMuteAll:
            toggleMuteAll()

        case .setRemoteGain(let preset):
            self.remoteGainPreset = preset
            AppStorage.remoteMicGainPreset = preset
            bleBridge.remoteGain = preset.linearGain
            AudioPipe.shared.setRemoteGainPreset(preset)
            broadcastState()

        case .testSpeak:
            toggleTestSpeak()

        case .installDriver(let desiredPolicy):
            installDriverFlow(desiredPolicy: desiredPolicy)

        case .uninstallDriver:
            uninstallDriverFlow()

        case .subscribeLevels(let enabled):
            self.hasSubscribedLevels = enabled
            syncAudioPipeCallbacks()

        case .quitDaemon:
            performSafeShutdown()
            exit(0)

        default:
            break
        }
    }

    private func syncAudioPipeCallbacks() {
        if hasSubscribedLevels {
            var lastMac: Float = -120
            var lastRemote: Float = -120
            var lastOut: Float = -120
            AudioPipe.shared.onMacLevel = { [weak self] db in
                lastMac = Float(db)
                self?.ipcServer.broadcast(.audioLevels(mac: lastMac, remote: lastRemote, output: lastOut))
            }
            AudioPipe.shared.onOutputLevel = { [weak self] db in
                lastOut = Float(db)
                self?.ipcServer.broadcast(.audioLevels(mac: lastMac, remote: lastRemote, output: lastOut))
            }
            bleBridge.onLevel = { [weak self] db in
                lastRemote = Float(db)
                self?.ipcServer.broadcast(.audioLevels(mac: lastMac, remote: lastRemote, output: lastOut))
            }
            AudioPipe.shared.setUIPreviewEnabled(isMacEnabled)
        } else {
            AudioPipe.shared.onMacLevel = nil
            AudioPipe.shared.onOutputLevel = nil
            bleBridge.onLevel = nil
            AudioPipe.shared.setUIPreviewEnabled(false)
        }
    }

    private func applyPolicy(_ policy: MicRoutingPolicy) {
        sessionCoordinator.stopAndReleaseAll()
        micPolicy = policy
        AppStorage.micPolicy = policy
        AudioPipe.shared.updatePolicy(policy)
        MicRouteCoordinator.apply(driverAvailable: driverInstalled, policy: policy, method: voiceInputMethod)
        broadcastState()
    }

    private func toggleMuteAll() {
        let newMuted = !allMuted
        allMuted = newMuted
        if newMuted {
            stopTestSpeak(sendStopShortcut: true)
            sessionCoordinator.stopAndReleaseAll()
            MicRouteCoordinator.endTransientVirtualRoute()
        }
        AudioPipe.shared.setAllMuted(newMuted)
        broadcastState()
    }

    private func cycleMicrophonePolicyFromRemote() {
        guard driverInstalled else { return }
        let order: [MicRoutingPolicy] = [.smartByTriggerSource, .macOnly, .remoteOnly, .dualMix]
        let idx = order.firstIndex(of: micPolicy) ?? 0
        let next = order[(idx + 1) % order.count]
        applyPolicy(next)
    }

    private func toggleTestSpeak() {
        if isTestSpeaking {
            stopTestSpeak(sendStopShortcut: true)
            return
        }
        if allMuted {
            ipcServer.broadcast(.toast(text: "双麦已关闭，请先恢复麦克风后再试说", positive: false))
            return
        }
        testSpeakTimeoutWork?.cancel()
        isTestSpeaking = true
        AudioPipe.shared.setSessionActive(true, triggerSource: .keyboard)
        InputTrigger.beginRecognition()
        broadcastState()

        let timeout = DispatchWorkItem { [weak self] in
            self?.stopTestSpeak(sendStopShortcut: true)
        }
        testSpeakTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 25.0, execute: timeout)
    }

    private func stopTestSpeak(sendStopShortcut: Bool) {
        testSpeakTimeoutWork?.cancel()
        testSpeakTimeoutWork = nil
        guard isTestSpeaking else { return }
        isTestSpeaking = false
        if sendStopShortcut {
            InputTrigger.endRecognition()
        }
        if !isRecording {
            AudioPipe.shared.setSessionActive(false, triggerSource: .none)
        }
        broadcastState()
    }

    private func installDriverFlow(desiredPolicy: MicRoutingPolicy) {
        stopTestSpeak(sendStopShortcut: true)
        sessionCoordinator.stopAndReleaseAll()
        AudioPipe.shared.shutdown()

        DriverManager.shared.installBundledDriver { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.driverInstalled = true
                self.allMuted = false
                self.isMacEnabled = true
                AudioPipe.shared.setAllMuted(false)
                self.audioStateMonitor.rebuildAfterAudioDaemonRestart()
                self.applyPolicy(desiredPolicy)
                AudioPipe.shared.rebuildAfterDriverChange(driverAvailable: true, policy: self.micPolicy)
                self.ipcServer.broadcast(.driverInstallResult(success: true, message: "内置音频驱动已启用，双麦就绪"))
                self.broadcastState()
            case .failure(let error):
                AudioPipe.shared.rebuildAfterDriverChange(driverAvailable: false, policy: .macOnly)
                self.ipcServer.broadcast(.driverInstallResult(success: false, message: error.localizedDescription))
                self.broadcastState()
            }
        }
    }

    private func uninstallDriverFlow() {
        stopTestSpeak(sendStopShortcut: true)
        sessionCoordinator.stopAndReleaseAll()
        AudioPipe.shared.shutdown()

        DriverManager.shared.uninstallDriver { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.driverInstalled = false
                self.doubaoRouteMismatch = false
                self.allMuted = false
                self.isMacEnabled = true
                self.micPolicy = .macOnly
                AppStorage.micPolicy = .macOnly
                AudioPipe.shared.setAllMuted(false)
                self.audioStateMonitor.rebuildAfterAudioDaemonRestart()
                AudioPipe.shared.rebuildAfterDriverChange(driverAvailable: false, policy: .macOnly)
                self.ipcServer.broadcast(.driverInstallResult(success: true, message: "已卸载遥控器声卡"))
                self.broadcastState()
            case .failure(let error):
                AudioPipe.shared.rebuildAfterDriverChange(driverAvailable: self.driverInstalled, policy: self.micPolicy)
                self.ipcServer.broadcast(.driverInstallResult(success: false, message: error.localizedDescription))
            }
        }
    }

    /// 启动或唤醒前台主控制台 App
    private func launchOrActivateConsole() {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            // 当前处于 .app 打包目录中，直接激活自身前台模式
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: NSWorkspace.OpenConfiguration()) { _, err in
                if let err {
                    AppLog.write("DAEMON", "唤起控制台失败: \(err.localizedDescription)")
                }
            }
        } else {
            // 开发测试模式：通过 open 命令启动自身（不带 --daemon 参数）
            let execPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let task = Process()
            task.executableURL = URL(fileURLWithPath: execPath)
            task.arguments = []
            try? task.run()
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
                AppLog.write("MAPPING", "随前台应用 \(app.localizedName ?? "") 自动切至 \(targetPreset.title)")
            }
        }
    }

    private func performSafeShutdown() {
        AppLog.write("DAEMON", "执行守护引擎安全退出")
        if let activeAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeAppObserver)
            self.activeAppObserver = nil
        }
        ipcServer.stop()
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
            exit(0)
        }
        term.resume()
        sigtermSource = term

        signal(SIGINT, SIG_IGN)
        let intr = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intr.setEventHandler { [weak self] in
            self?.performSafeShutdown()
            exit(0)
        }
        intr.resume()
        sigintSource = intr
    }
}
