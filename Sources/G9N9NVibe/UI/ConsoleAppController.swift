import AppKit
import Foundation

/// G9NVibe 前台交互控制台控制器：
/// - 纯粹的配置与控制界面，通过 VibeIPCClient 与后台 G9NDaemon 高速通信；
/// - 用户关闭主窗口（×）后进程直接彻底退出，内存 100% 归还操作系统；
/// - 下次点击 Dock 图标或菜单栏「打开控制台」时秒开冷启动，从 Daemon 获取最新快照瞬间恢复！
final class ConsoleAppController: NSObject, NSApplicationDelegate {
    private let viewModel = AppViewModel()
    private let mappingStore = RemoteMappingStore.shared
    private lazy var mainWindowController = MainWindowController(viewModel: viewModel, mappingStore: mappingStore)
    private let ipcClient = VibeIPCClient()
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.setup()
        AppLog.write("UI", "G9NVibe 控制台启动 (PID: \(ProcessInfo.processInfo.processIdentifier))")

        // 1. 确保后台守护引擎正在运行
        ensureDaemonRunning()

        // 2. 连接守护引擎 IPC
        wireIPC()

        // 3. 关联 ViewModel 交互操作
        wireViewModel()

        // 4. 设置主菜单
        setupMainMenu()

        // 5. 展示主控制台
        viewModel.refreshPermissions()
        viewModel.launchAtLogin = LaunchAtLogin.isEnabled
        mainWindowController.showWindow()

        // 首次安装自动引导
        if !AppStorage.hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.viewModel.showOnboarding = true
            }
        }

        // 版本升级横幅
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
        }
        AppStorage.lastLaunchedVersion = currentVersion

        // 默认若在音频页面，订阅电平
        if viewModel.currentPage == .audio {
            ipcClient.send(.subscribeLevels(true))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 核心解耦关键：用户关闭控制台窗口后，前台进程彻底退出！
        // 内存 100% 释放给内核，后台仅保留 6~8MB 的极简 G9NDaemon！
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        ipcClient.send(.subscribeLevels(false))
        ipcClient.disconnect()
        AppLog.write("UI", "前台控制台进程退出完毕")
    }

    private func ensureDaemonRunning() {
        let testClient = VibeIPCClient()
        if testClient.connect() {
            testClient.disconnect()
            return
        }

        // 尝试启动后台守护进程
        let execPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        AppLog.write("UI", "检测到守护引擎未在运行，正在以后台模式启动: \(execPath)")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: execPath)
        task.arguments = ["--daemon"]
        try? task.run()

        // 等待 150ms 供守护进程完成 socket 绑定
        usleep(150_000)
    }

    private func wireIPC() {
        ipcClient.onMessageReceived = { [weak self] msg in
            self?.handleDaemonMessage(msg)
        }

        ipcClient.onConnectionStatusChanged = { [weak self] connected in
            guard let self else { return }
            if connected {
                AppLog.write("UI", "已成功连上后台守护引擎，请求状态快照")
                self.ipcClient.send(.getState)
                if self.viewModel.currentPage == .audio {
                    self.ipcClient.send(.subscribeLevels(true))
                }
            } else if !self.isTerminating {
                AppLog.write("UI", "与后台守护引擎断开连接")
            }
        }

        _ = ipcClient.connect()
    }

    private func handleDaemonMessage(_ msg: IPCMessage) {
        switch msg {
        case .stateSnapshot(let snap):
            viewModel.bleConnected = snap.bleConnected
            viewModel.hidConnected = snap.hidConnected
            viewModel.remoteBatteryLevel = snap.remoteBatteryLevel
            viewModel.driverInstalled = snap.driverInstalled
            viewModel.micPolicy = snap.micPolicy
            viewModel.voiceInputMethod = snap.voiceInputMethod
            viewModel.triggerShortcut = snap.voiceTriggerShortcut
            viewModel.triggerMode = snap.triggerMode
            viewModel.isRecording = snap.isRecording
            viewModel.isTestSpeaking = snap.isTestSpeaking
            viewModel.allMuted = snap.allMuted
            viewModel.remoteGainPreset = snap.remoteGainPreset
            viewModel.sessionStatusText = snap.sessionStatusText
            viewModel.activeTriggerSource = snap.activeTriggerSource
            viewModel.doubaoRouteMismatch = snap.doubaoRouteMismatch

        case .audioLevels(let mac, let remote, let output):
            viewModel.macLevelDb = Double(mac)
            viewModel.remoteLevelDb = Double(remote)
            viewModel.outputLevelDb = Double(output)

        case .buttonPressed(let buttonID, let isDown):
            if isDown {
                viewModel.selectedButtonID = buttonID
                viewModel.triggerRemoteLedPulse()
            }

        case .toast(let text, let positive):
            viewModel.showToast(text, positive: positive)

        case .driverInstallResult(let success, let message):
            viewModel.showToast(message, positive: success)

        default:
            break
        }
    }

    private func wireViewModel() {
        viewModel.onPolicyChanged = { [weak self] policy in
            self?.ipcClient.send(.setPolicy(policy))
        }

        viewModel.onInputMethodChanged = { [weak self] method in
            self?.ipcClient.send(.setInputMethod(method))
        }

        viewModel.onTriggerShortcutChanged = { [weak self] shortcut in
            self?.ipcClient.send(.setTriggerShortcut(shortcut))
        }

        viewModel.onTriggerModeChanged = { [weak self] mode in
            self?.ipcClient.send(.setTriggerMode(mode))
        }

        viewModel.onAllMutedChanged = { [weak self] _ in
            self?.ipcClient.send(.toggleMuteAll)
        }

        viewModel.onRemoteGainChanged = { [weak self] preset in
            self?.ipcClient.send(.setRemoteGain(preset))
        }

        viewModel.onTestSpeakRequested = { [weak self] in
            self?.ipcClient.send(.testSpeak)
        }

        viewModel.onRequestInstallDriver = { [weak self] desiredPolicy in
            self?.ipcClient.send(.installDriver(desiredPolicy: desiredPolicy))
        }

        viewModel.onRequestUninstallDriver = { [weak self] in
            self?.ipcClient.send(.uninstallDriver)
        }

        viewModel.onPageChanged = { [weak self] page in
            self?.ipcClient.send(.subscribeLevels(page == .audio))
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: "G9NVibe")
        let updateItem = NSMenuItem(title: "检查更新…", action: #selector(handleCheckUpdatesMenu), keyEquivalent: "u")
        updateItem.target = self
        appMenu.addItem(updateItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "关闭控制台（保持后台运行）", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(NSMenuItem(title: "隐藏 G9NVibe", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "彻底退出 G9NVibe (包括后台守护)", action: #selector(handleQuitAll), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func handleCheckUpdatesMenu() {
        viewModel.openUpdateDialog()
    }

    @objc private func handleQuitAll() {
        // 请求后台守护进程也退出
        ipcClient.send(.quitDaemon)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.terminate(nil)
        }
    }
}
