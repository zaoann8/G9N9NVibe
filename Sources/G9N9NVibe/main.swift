import AppKit
import Foundation

// MARK: - 自动化状态机与业务逻辑自测入口

#if DEBUG
if CommandLine.arguments.contains("--voice-session-self-test") {
    VoiceSessionSelfTest.runAll()
    exit(0)
}
#endif

// MARK: - 单二进制双角色分流（Karabiner 工业级架构）

let isDaemonMode = CommandLine.arguments.contains("--daemon")

if isDaemonMode {
    // 1. 后台守护引擎角色：
    // 设置为 .accessory 模式（纯菜单栏常驻，无 Dock 图标，内存占用仅 6~8MB）
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let daemon = DaemonController()
    daemon.start()
    app.run()
} else {
    // 2. 前台控制台角色：
    // 设置为 .regular 模式（拥有 Dock 栏图标与 960x660 主控制台）
    // 单实例控制：若已有前台控制台在运行，直接激活并退出当前冗余进程
    let currentPID = ProcessInfo.processInfo.processIdentifier
    let bundleID = Bundle.main.bundleIdentifier ?? "io.github.g9n9n-vibe"
    let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    let otherInstances = runningApps.filter { $0.processIdentifier != currentPID && $0.activationPolicy == .regular }
    if let existing = otherInstances.first {
        existing.activate(options: [.activateIgnoringOtherApps])
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let console = ConsoleAppController()
    app.delegate = console
    app.run()
}
