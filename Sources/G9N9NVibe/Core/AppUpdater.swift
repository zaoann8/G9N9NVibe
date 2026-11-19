import AppKit
import CryptoKit
import Foundation

/// GitHub Release 版本信息模型
struct ReleaseUpdateInfo: Equatable {
    let version: String
    let tagName: String
    let releaseNotes: String
    let releasePageURL: URL
    let dmgDownloadURL: URL?
    let dmgFileName: String?
    let dmgFileSize: Int64?
    let sha256AssetURL: URL?
}

/// 自更新状态机
enum AppUpdateState: Equatable {
    case idle
    case checking
    case upToDate(currentVersion: String)
    case available(ReleaseUpdateInfo)
    case downloading(ReleaseUpdateInfo, progress: Double)
    case verifying(ReleaseUpdateInfo)
    case installing(ReleaseUpdateInfo)
    case notConfigured
    case failed(String)

    var hasAvailableUpdate: Bool {
        if case .available = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .verifying, .installing:
            return true
        default:
            return false
        }
    }
}

/// G9NVibe 零第三方依赖原生自动更新引擎：
/// - 通过 GitHub Releases API 检查 SemVer 语义化新版本（每天静默检查一次 + 随时手动检查）
/// - 支持实时进度下载 DMG + CryptoKit SHA-256 完整性校验 + 静默 hdiutil 挂载 + codesign 验包
/// - 支持无损 TCC 权限保留的安全静默升级（失败自动回滚旧包）+ 清除 quarantine 隔离标记 + 自动重启
final class AppUpdater: NSObject, URLSessionDownloadDelegate {
    static let shared = AppUpdater()

    var onStateChanged: ((AppUpdateState) -> Void)?
    /// 即将重启应用以完成静默更新前回调（由 AppController 执行安全退出与系统麦还原）
    var onWillTerminateForUpdate: (() -> Void)?

    private(set) var state: AppUpdateState = .idle {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onStateChanged?(self.state)
            }
        }
    }

    private var downloadSession: URLSession?
    private var activeDownloadTask: URLSessionDownloadTask?
    private var activeRelease: ReleaseUpdateInfo?
    private var activeTempDir: URL?

    private override init() {
        super.init()
    }

    // MARK: - SemVer 语义化版本与 SHA-256 纯函数工具（供单元测试直接验证）

    /// 语义化版本比较：正确判定 "1.0.10" > "1.0.2"、"v1.2.0" > "1.1.9"
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = parseSemVer(candidate)
        let rhs = parseSemVer(current)
        let maxCount = max(lhs.count, rhs.count)
        for idx in 0..<maxCount {
            let a = idx < lhs.count ? lhs[idx] : 0
            let b = idx < rhs.count ? rhs[idx] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func parseSemVer(_ raw: String) -> [Int] {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("v") {
            cleaned.removeFirst()
        }
        // 剥离预发布/构建后缀（如 -beta.1 / +2026）
        if let dash = cleaned.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            cleaned = String(cleaned[..<dash])
        }
        return cleaned.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// 从标准 `shasum -a 256` 文本中提取 64 位小写十六进制摘要
    static func parseSHA256Text(_ text: String) -> String? {
        let token = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)?
            .lowercased()
        guard let token, token.count == 64,
              token.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            return nil
        }
        return token
    }

    /// 计算本地文件 SHA-256 哈希（流式分块读取，零大内存峰值）
    static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 决定覆盖安装的安全目标路径（避开只读 DMG 卷、AppTranslocation 隔离区和 swift run 开发目录）
    static func resolveInstallTargetURL(bundleURL: URL = Bundle.main.bundleURL) -> URL {
        let path = bundleURL.path
        let isAppBundle = bundleURL.pathExtension.lowercased() == "app"
        let inReadOnlyVolume = path.hasPrefix("/Volumes/")
        let inTranslocation = path.contains("AppTranslocation")
        let inBuildDir = path.contains("/.build/")
        if isAppBundle && !inReadOnlyVolume && !inTranslocation && !inBuildDir {
            return bundleURL
        }
        return URL(fileURLWithPath: "/Applications/G9NVibe.app")
    }

    // MARK: - 检查更新

    /// 启动后静默检查（每 24 小时最多自动检查一次，防止触碰 GitHub 匿名限流）
    func checkSilentlyIfDue() {
        guard !AppStorage.githubRepository.isEmpty else { return }
        if let last = AppStorage.lastUpdateCheckDate,
           Date().timeIntervalSince(last) < 24 * 3600 {
            return
        }
        checkForUpdates(userInitiated: false)
    }

    /// 检查 GitHub Releases 最新版本
    func checkForUpdates(userInitiated: Bool) {
        if state.isBusy { return }
        let repo = AppStorage.githubRepository
        guard !repo.isEmpty else {
            if userInitiated {
                state = .notConfigured
            }
            return
        }

        state = .checking
        let currentVersion = AppStorage.appVersionString
        guard let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            state = .failed("更新源仓库地址格式无效：\(repo)")
            return
        }

        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("G9NVibe/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                AppLog.write("UPDATE", "检查更新失败: \(error.localizedDescription)")
                self.state = userInitiated ? .failed("网络连接失败：\(error.localizedDescription)") : .idle
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let msg = (http.statusCode == 404)
                    ? "仓库尚未发布任何 Release 版本"
                    : "GitHub 接口返回异常状态码 (\(http.statusCode))"
                AppLog.write("UPDATE", msg)
                self.state = userInitiated ? .failed(msg) : .idle
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                self.state = userInitiated ? .failed("无法解析 GitHub Release 信息") : .idle
                return
            }

            AppStorage.lastUpdateCheckDate = Date()
            let cleanVersion = tagName.hasPrefix("v") || tagName.hasPrefix("V") ? String(tagName.dropFirst()) : tagName
            let notes = (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let htmlURLString = (json["html_url"] as? String) ?? "https://github.com/\(repo)/releases/latest"
            let pageURL = URL(string: htmlURLString) ?? URL(string: "https://github.com/\(repo)/releases/latest")!

            let assets = json["assets"] as? [[String: Any]] ?? []
            let dmgAsset = assets.first {
                (($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true)
            }
            let shaAsset = assets.first {
                (($0["name"] as? String)?.lowercased().hasSuffix(".sha256") == true)
            }

            let info = ReleaseUpdateInfo(
                version: cleanVersion,
                tagName: tagName,
                releaseNotes: notes,
                releasePageURL: pageURL,
                dmgDownloadURL: (dmgAsset?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                dmgFileName: dmgAsset?["name"] as? String,
                dmgFileSize: (dmgAsset?["size"] as? NSNumber)?.int64Value,
                sha256AssetURL: (shaAsset?["browser_download_url"] as? String).flatMap(URL.init(string:))
            )

            if Self.isVersion(cleanVersion, newerThan: currentVersion) {
                AppLog.write("UPDATE", "发现新版本: \(cleanVersion) (当前 \(currentVersion))")
                self.state = .available(info)
            } else {
                AppLog.write("UPDATE", "当前已是最新版本 \(currentVersion)")
                self.state = userInitiated ? .upToDate(currentVersion: currentVersion) : .idle
            }
        }.resume()
    }

    // MARK: - 下载、校验与安全静默安装

    func startDownloadAndInstall(_ info: ReleaseUpdateInfo) {
        guard !state.isBusy else { return }
        guard let dmgURL = info.dmgDownloadURL else {
            NSWorkspace.shared.open(info.releasePageURL)
            state = .failed("该 Release 未附带 DMG 文件，已为你打开 GitHub 页面手动下载")
            return
        }

        cancelActiveDownload()
        activeRelease = info

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("G9NVibeUpdate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        activeTempDir = tmpDir

        state = .downloading(info, progress: 0)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        downloadSession = session
        let task = session.downloadTask(with: dmgURL)
        activeDownloadTask = task
        task.resume()
        AppLog.write("UPDATE", "开始下载新版本 DMG: \(dmgURL.absoluteString)")
    }

    func cancelActiveDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        if let dir = activeTempDir {
            try? FileManager.default.removeItem(at: dir)
            activeTempDir = nil
        }
        if case .downloading(let info, _) = state {
            state = .available(info)
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let info = activeRelease else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (info.dmgFileSize ?? 0)
        let progress = expected > 0 ? min(0.99, Double(totalBytesWritten) / Double(expected)) : 0
        state = .downloading(info, progress: progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let info = activeRelease, let tmpDir = activeTempDir else { return }
        let dmgFile = tmpDir.appendingPathComponent(info.dmgFileName ?? "G9NVibe-update.dmg")
        do {
            if FileManager.default.fileExists(atPath: dmgFile.path) {
                try FileManager.default.removeItem(at: dmgFile)
            }
            try FileManager.default.moveItem(at: location, to: dmgFile)
        } catch {
            failAndCleanup("保存下载包失败：\(error.localizedDescription)")
            return
        }

        downloadSession?.finishTasksAndInvalidate()
        downloadSession = nil
        activeDownloadTask = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.verifyAndInstall(dmgURL: dmgFile, info: info, tempDir: tmpDir)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
            return
        }
        failAndCleanup("下载失败：\(error.localizedDescription)")
    }

    // MARK: - 完整性校验、静默挂载与原子级覆盖替换

    private func verifyAndInstall(dmgURL: URL, info: ReleaseUpdateInfo, tempDir: URL) {
        state = .verifying(info)

        // 1. 若 Release 提供 .sha256 文件，则严格校验下载包哈希防篡改与损坏
        if let shaURL = info.sha256AssetURL {
            do {
                let shaText = try String(contentsOf: shaURL, encoding: .utf8)
                if let expected = Self.parseSHA256Text(shaText) {
                    let actual = try Self.sha256Hex(of: dmgURL)
                    guard actual == expected else {
                        failAndCleanup("安装包 SHA-256 校验失败，已中止覆盖以保护原应用")
                        return
                    }
                    AppLog.write("UPDATE", "SHA-256 完整性校验通过: \(actual)")
                }
            } catch {
                AppLog.write("UPDATE", "读取 .sha256 校验文件失败，继续使用 codesign 验包: \(error.localizedDescription)")
            }
        }

        // 2. 静默只读挂载 DMG（绝不弹出 Finder 窗口）
        let mountDir = tempDir.appendingPathComponent("mount", isDirectory: true)
        try? FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)

        let attach = runCommand("/usr/bin/hdiutil", args: [
            "attach", dmgURL.path,
            "-nobrowse", "-readonly", "-noautoopen",
            "-mountpoint", mountDir.path
        ])
        guard attach.exitCode == 0 else {
            failAndCleanup("挂载安装包失败：\(attach.stderr)")
            return
        }
        defer {
            _ = runCommand("/usr/bin/hdiutil", args: ["detach", mountDir.path, "-force"])
        }

        // 3. 定位新包并拷贝至独立 staging 区 + codesign 严格验包
        let mountedApp = mountDir.appendingPathComponent("G9NVibe.app")
        guard FileManager.default.fileExists(atPath: mountedApp.path) else {
            failAndCleanup("安装包内未找到 G9NVibe.app")
            return
        }

        let stagedApp = tempDir.appendingPathComponent("G9NVibe.app")
        let copyResult = runCommand("/usr/bin/ditto", args: [mountedApp.path, stagedApp.path])
        guard copyResult.exitCode == 0 else {
            failAndCleanup("提取新版本应用失败：\(copyResult.stderr)")
            return
        }

        // 清除从网络下载附带的隔离标记，防止覆盖重启后再次触发 Gatekeeper 弹窗
        _ = runCommand("/usr/bin/xattr", args: ["-cr", stagedApp.path])

        let verifySign = runCommand("/usr/bin/codesign", args: ["--verify", "--deep", "--strict", stagedApp.path])
        guard verifySign.exitCode == 0 else {
            failAndCleanup("新版本签名完整性验证未通过，已安全中止更新")
            return
        }

        // 4. 启动脱离式安全覆盖替换 + 失败自动回滚 + 自动重启脚本
        state = .installing(info)
        let targetApp = Self.resolveInstallTargetURL()
        let parentDir = targetApp.deletingLastPathComponent()
        let needsPrivilege = !FileManager.default.isWritableFile(atPath: parentDir.path)

        do {
            try launchAtomicReplaceAndRestart(
                stagedApp: stagedApp,
                targetApp: targetApp,
                tempDir: tempDir,
                needsPrivilege: needsPrivilege
            )
            AppLog.write("UPDATE", "已派发安全覆盖更新脚本 -> \(targetApp.path)，主程序即将安全退出并重启")
            DispatchQueue.main.async { [weak self] in
                self?.onWillTerminateForUpdate?()
                // 彻底关闭并隐藏所有窗口，避免残留更新弹窗或阻碍进程退出
                for window in NSApp.windows {
                    window.orderOut(nil)
                    window.close()
                }
                NSApp.terminate(nil)
                // 延时 0.15 秒兜底强退，确保旧进程彻底退出，绝不留存双实例
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    exit(0)
                }
            }
        } catch {
            failAndCleanup("启动覆盖安装失败：\(error.localizedDescription)")
        }
    }

    private func launchAtomicReplaceAndRestart(
        stagedApp: URL,
        targetApp: URL,
        tempDir: URL,
        needsPrivilege: Bool
    ) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let parentDir = targetApp.deletingLastPathComponent().path
        let backupPath = "\(parentDir)/.G9NVibe.backup-\(pid).app"
        let newSlotPath = "\(parentDir)/.G9NVibe.new-\(pid).app"
        let scriptURL = tempDir.appendingPathComponent("apply-update.sh")

        // 脱离子进程脚本：等待旧 PID 退出（超时强杀）-> 复制到同分区临时槽 -> 安全切换（失败自动回滚）-> 重启新版
        let coreBody = """
        set -e
        TARGET=\(shellQuote(targetApp.path))
        STAGED=\(shellQuote(stagedApp.path))
        BACKUP=\(shellQuote(backupPath))
        NEWSLOT=\(shellQuote(newSlotPath))
        TMPDIR=\(shellQuote(tempDir.path))

        # 1. 优先等待旧主进程优雅退出（最多等 2 秒）
        for _ in {1..20}; do
          if ! kill -0 \(pid) 2>/dev/null; then break; fi
          sleep 0.1
        done

        # 若旧主进程未及时退出，坚决强制终止旧主进程，防止多开两个 App 或两个窗口
        if kill -0 \(pid) 2>/dev/null; then
          kill -9 \(pid) 2>/dev/null || true
          sleep 0.2
        fi

        # 2. 先拷贝到同分区新槽位并清隔离标记，确保后续 mv 为瞬时原子操作
        rm -rf "$NEWSLOT" "$BACKUP"
        /usr/bin/ditto "$STAGED" "$NEWSLOT"
        /usr/bin/xattr -cr "$NEWSLOT" || true

        # 3. 安全替换并在任何异常时立即无损回滚旧版本
        if [ -d "$TARGET" ]; then
          mv "$TARGET" "$BACKUP"
        fi
        if ! mv "$NEWSLOT" "$TARGET"; then
          if [ -d "$BACKUP" ]; then
            mv "$BACKUP" "$TARGET" || true
          fi
          exit 1
        fi

        # 4. 清理备份与临时目录，标准唤起启动全新版本（去除 -n 参数，严格维持单实例）
        rm -rf "$BACKUP" "$TMPDIR"
        /usr/bin/open "$TARGET"
        """

        try ("#!/bin/zsh\n" + coreBody + "\n").write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = runCommand("/bin/chmod", args: ["+x", scriptURL.path])

        if needsPrivilege {
            // 若目标目录不可写（例如标准用户权限），弹系统原生密码/触控 ID 框执行覆盖脚本
            let escaped = shellQuote(scriptURL.path)
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", "do shell script \"/bin/zsh \(escaped) >/dev/null 2>&1 &\" with administrator privileges"]
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw BridgeError.protocolFailure("用户取消了管理员授权")
            }
        } else {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-c", "/bin/zsh \(shellQuote(scriptURL.path)) >/dev/null 2>&1 &"]
            try proc.run()
        }
    }

    private func failAndCleanup(_ message: String) {
        AppLog.write("UPDATE", message)
        if let dir = activeTempDir {
            try? FileManager.default.removeItem(at: dir)
            activeTempDir = nil
        }
        state = .failed(message)
    }

    private func runCommand(_ executable: String, args: [String]) -> (exitCode: Int32, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (proc.terminationStatus, errStr)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
