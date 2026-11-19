import Foundation

/// 自愈型开机自启管理（通过 LaunchAgents plist 实现，支持覆盖安装后自动修正指向路径）
enum LaunchAtLogin {
    private static let label = AppStorage.bundleIdentifier
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            writeAgentPlist()
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }

    /// 每次启动时校验旧启动项：若指向的路径已失效或当前已安装到 /Applications，则自动修正
    static func repairIfStale() {
        guard isEnabled,
              let data = try? Data(contentsOf: plistURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = dict["ProgramArguments"] as? [String],
              let recordedPath = args.first else {
            return
        }
        let currentExecutable = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
        guard recordedPath != currentExecutable else { return }
        let recordedExists = FileManager.default.fileExists(atPath: recordedPath)
        let inApplications = currentExecutable.hasPrefix("/Applications/")
        if !recordedExists || inApplications {
            writeAgentPlist()
            AppLog.write("LOGIN", "已将旧开机启动项路径修正为: \(currentExecutable)")
        }
    }

    private static func writeAgentPlist() {
        let executable = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--daemon"],
            "RunAtLoad": true,
            "KeepAlive": false
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
            try? data.write(to: plistURL, options: .atomic)
        }
    }
}
