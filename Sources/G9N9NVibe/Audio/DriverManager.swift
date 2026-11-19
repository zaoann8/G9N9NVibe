import AppKit
import CoreAudio
import Foundation

/// 内置自研虚拟音频驱动（G9N9NVibeMic.driver）的安装、热重载与无痕卸载管理器
final class DriverManager {
    static let shared = DriverManager()

    static let installedDriverPath = "/Library/Audio/Plug-Ins/HAL/\(AppStorage.virtualDriverBundleName)"

    var onDriverAvailabilityChanged: ((Bool) -> Void)?

    private var hardwareListenerInstalled = false
    private lazy var devicesListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async {
            guard let self else { return }
            self.onDriverAvailabilityChanged?(self.isDriverActiveInCoreAudio)
        }
    }

    private init() {}

    /// 驱动文件是否已部署到系统 HAL 目录
    var isDriverBundleInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.installedDriverPath)
    }

    /// 驱动是否已被 coreaudiod 加载且在系统中可见
    var isDriverActiveInCoreAudio: Bool {
        MicRouteCoordinator.virtualMicDeviceID() != nil
    }

    /// 定位内置的 .driver 包（打包在 App Resources 中，开发调试时回落到 DriverSource/build）
    func bundledDriverURL() -> URL? {
        if let resURL = Bundle.main.resourceURL?
            .appendingPathComponent("Driver/\(AppStorage.virtualDriverBundleName)"),
           FileManager.default.fileExists(atPath: resURL.path) {
            return resURL
        }
        // 开发阶段直接运行 swift build 时的本地回落路径
        let cwd = FileManager.default.currentDirectoryPath
        let devPaths = [
            "\(cwd)/DriverSource/build/\(AppStorage.virtualDriverBundleName)",
            "\(cwd)/G9N9N-Vibe/DriverSource/build/\(AppStorage.virtualDriverBundleName)"
        ]
        for path in devPaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    func startObservingHardwareChanges() {
        guard !hardwareListenerInstalled else { return }
        hardwareListenerInstalled = true
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            .main,
            devicesListener
        )
    }

    /// 一键提权安装内置驱动并热重载 coreaudiod（触发系统原生触控 ID / 密码弹窗，无需终端）
    func installBundledDriver(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let sourceURL = bundledDriverURL() else {
            completion(.failure(BridgeError.protocolFailure("应用包内未找到内置驱动文件 \(AppStorage.virtualDriverBundleName)")))
            return
        }

        let src = shellQuote(sourceURL.path)
        let dst = shellQuote(Self.installedDriverPath)
        // 采用严格单行 && 连接，彻底消除多行字符串换行与反斜杠转义在 AppleScript 上的兼容性隐患
        let script = [
            "mkdir -p /Library/Audio/Plug-Ins/HAL",
            "rm -rf \(dst)",
            "ditto \(src) \(dst)",
            "chown -R root:wheel \(dst)",
            "chmod -R 755 \(dst)",
            "launchctl kickstart -kp system/com.apple.audio.coreaudiod"
        ].joined(separator: " && ")

        runPrivilegedShell(script) { [weak self] result in
            switch result {
            case .failure(let err):
                completion(.failure(err))
            case .success:
                // coreaudiod 重启约需 0.5~1.5 秒，提供多达 16 次（约 4.8 秒）轮询重试，从容应对高负载
                self?.waitForDriverOnline(remainingAttempts: 16) { online in
                    if online {
                        completion(.success(()))
                    } else {
                        completion(.failure(BridgeError.protocolFailure("驱动已部署，但核心音频服务尚未刷出虚拟声卡设备，请稍候片刻再试")))
                    }
                }
            }
        }
    }

    /// 一键无痕卸载驱动并热恢复纯免驱态
    func uninstallDriver(completion: @escaping (Result<Void, Error>) -> Void) {
        // 先无损还原系统默认麦克风，避免卸载后默认输入悬空
        MicRouteCoordinator.restoreOriginalInputDevice(force: true)

        let dst = shellQuote(Self.installedDriverPath)
        let script = "rm -rf \(dst) && launchctl kickstart -kp system/com.apple.audio.coreaudiod"

        runPrivilegedShell(script) { result in
            switch result {
            case .failure(let err):
                completion(.failure(err))
            case .success:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    completion(.success(()))
                }
            }
        }
    }

    private func waitForDriverOnline(remainingAttempts: Int, completion: @escaping (Bool) -> Void) {
        if isDriverActiveInCoreAudio {
            completion(true)
            return
        }
        guard remainingAttempts > 0 else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.waitForDriverOnline(remainingAttempts: remainingAttempts - 1, completion: completion)
        }
    }

    private func runPrivilegedShell(_ command: String, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let escaped = command
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]

            let errPipe = Pipe()
            process.standardError = errPipe

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    DispatchQueue.main.async { completion(.success(())) }
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "用户取消授权或执行失败"
                    DispatchQueue.main.async {
                        completion(.failure(BridgeError.protocolFailure(errText)))
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
