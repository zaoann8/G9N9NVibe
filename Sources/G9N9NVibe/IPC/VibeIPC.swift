import Foundation

/// G9NVibe 进程间通信（IPC）常量定义
enum VibeIPCConstants {
    /// 守护进程 Unix Domain Socket 路径
    static var socketPath: String {
        let baseDir = ("~/.g9nvibe" as NSString).expandingTildeInPath
        return "\(baseDir)/daemon.sock"
    }

    /// 守护进程运行目录
    static var baseDirectory: String {
        ("~/.g9nvibe" as NSString).expandingTildeInPath
    }
}

/// 守护进程全量状态快照（前台控制台连上后秒级完成界面同步）
struct DaemonStateSnapshot: Codable {
    var bleConnected: Bool
    var hidConnected: Bool
    var remoteBatteryLevel: Int?
    var driverInstalled: Bool
    var micPolicy: MicRoutingPolicy
    var voiceInputMethod: VoiceInputMethod
    var voiceTriggerShortcut: VoiceTriggerShortcut
    var triggerMode: InputTriggerMode
    var isRecording: Bool
    var isTestSpeaking: Bool
    var allMuted: Bool
    var isMacEnabled: Bool
    var remoteGainPreset: RemoteMicGainPreset
    var sessionStatusText: String
    var activeTriggerSource: SessionTriggerSource
    var doubaoRouteMismatch: Bool
    var appVersion: String

    init(
        bleConnected: Bool = false,
        hidConnected: Bool = false,
        remoteBatteryLevel: Int? = nil,
        driverInstalled: Bool = false,
        micPolicy: MicRoutingPolicy = .macOnly,
        voiceInputMethod: VoiceInputMethod = .generic,
        voiceTriggerShortcut: VoiceTriggerShortcut = .rightOption,
        triggerMode: InputTriggerMode = .hold,
        isRecording: Bool = false,
        isTestSpeaking: Bool = false,
        allMuted: Bool = false,
        isMacEnabled: Bool = true,
        remoteGainPreset: RemoteMicGainPreset = .standard,
        sessionStatusText: String = "等待录音",
        activeTriggerSource: SessionTriggerSource = .none,
        doubaoRouteMismatch: Bool = false,
        appVersion: String = AppStorage.appVersionString
    ) {
        self.bleConnected = bleConnected
        self.hidConnected = hidConnected
        self.remoteBatteryLevel = remoteBatteryLevel
        self.driverInstalled = driverInstalled
        self.micPolicy = micPolicy
        self.voiceInputMethod = voiceInputMethod
        self.voiceTriggerShortcut = voiceTriggerShortcut
        self.triggerMode = triggerMode
        self.isRecording = isRecording
        self.isTestSpeaking = isTestSpeaking
        self.allMuted = allMuted
        self.isMacEnabled = isMacEnabled
        self.remoteGainPreset = remoteGainPreset
        self.sessionStatusText = sessionStatusText
        self.activeTriggerSource = activeTriggerSource
        self.doubaoRouteMismatch = doubaoRouteMismatch
        self.appVersion = appVersion
    }
}

/// 进程间交换的消息格式定义
enum IPCMessage: Codable {
    // MARK: - 客户端（前台界面）-> 服务端（守护引擎）
    case getState
    case setPolicy(MicRoutingPolicy)
    case setInputMethod(VoiceInputMethod)
    case setTriggerShortcut(VoiceTriggerShortcut)
    case setTriggerMode(InputTriggerMode)
    case toggleMuteAll
    case setRemoteGain(RemoteMicGainPreset)
    case testSpeak
    case installDriver(desiredPolicy: MicRoutingPolicy)
    case uninstallDriver
    case subscribeLevels(Bool)
    case quitDaemon

    // MARK: - 服务端（守护引擎）-> 客户端（前台界面）
    case stateSnapshot(DaemonStateSnapshot)
    case buttonPressed(buttonID: String, isDown: Bool) // 按键按下或松开（驱动左侧遥控器联动高亮）
    case audioLevels(mac: Float, remote: Float, output: Float)
    case toast(text: String, positive: Bool)
    case driverInstallResult(success: Bool, message: String)
}

// MARK: - 服务端（运行在 G9NDaemon 中）

final class VibeIPCServer {
    private let socketPath: String
    private var listenSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var clientBuffers: [Int32: Data] = [:]
    private let queue = DispatchQueue(label: "io.github.g9n9n-vibe.ipc.server", qos: .userInteractive)

    var onMessageReceived: ((IPCMessage, Int32) -> Void)?
    var onClientConnected: ((Int32) -> Void)?
    var onClientDisconnected: ((Int32) -> Void)?

    init(socketPath: String = VibeIPCConstants.socketPath) {
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    func start() -> Bool {
        stop()

        // 确保父目录存在
        let parentDir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        // 设置非阻塞
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { ptr in
            _ = strncpy(&addr.sun_path.0, ptr, maxLen - 1)
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                bind(fd, saPtr, addrLen)
            }
        }

        guard bindResult == 0, listen(fd, 8) == 0 else {
            close(fd)
            return false
        }

        // 限制文件权限，仅允许当前用户读写
        chmod(socketPath, 0o700)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnections(listenFd: fd)
        }
        source.setCancelHandler {
            close(fd)
            unlink(self.socketPath)
        }
        source.resume()
        self.listenSource = source
        return true
    }

    func stop() {
        for (clientFd, src) in clientSources {
            src.cancel()
            close(clientFd)
        }
        clientSources.removeAll()
        clientBuffers.removeAll()

        listenSource?.cancel()
        listenSource = nil
        unlink(socketPath)
    }

    private func acceptConnections(listenFd: Int32) {
        while true {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    accept(listenFd, saPtr, &clientLen)
                }
            }
            guard clientFd >= 0 else { break }

            let flags = fcntl(clientFd, F_GETFL, 0)
            _ = fcntl(clientFd, F_SETFL, flags | O_NONBLOCK)

            let clientSource = DispatchSource.makeReadSource(fileDescriptor: clientFd, queue: queue)
            clientSource.setEventHandler { [weak self] in
                self?.readClientData(clientFd: clientFd)
            }
            clientSource.setCancelHandler { [weak self] in
                close(clientFd)
                self?.clientSources.removeValue(forKey: clientFd)
                self?.clientBuffers.removeValue(forKey: clientFd)
                self?.onClientDisconnected?(clientFd)
            }
            clientSources[clientFd] = clientSource
            clientBuffers[clientFd] = Data()
            clientSource.resume()

            onClientConnected?(clientFd)
        }
    }

    private func readClientData(clientFd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(clientFd, &buffer, buffer.count)
            if bytesRead > 0 {
                clientBuffers[clientFd, default: Data()].append(buffer, count: bytesRead)
            } else if bytesRead == 0 {
                // 对端正常关闭
                clientSources[clientFd]?.cancel()
                break
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                }
                // 读取出错
                clientSources[clientFd]?.cancel()
                break
            }
        }

        // 解析以换行符分隔的 JSON 数据包
        guard var data = clientBuffers[clientFd] else { return }
        while let newlineIndex = data.firstIndex(of: 0x0A) { // '\n'
            let lineData = data.subdata(in: 0..<newlineIndex)
            data.removeSubrange(0...newlineIndex)
            if !lineData.isEmpty {
                if let msg = try? JSONDecoder().decode(IPCMessage.self, from: lineData) {
                    onMessageReceived?(msg, clientFd)
                }
            }
        }
        clientBuffers[clientFd] = data
    }

    /// 向所有已连接的客户端广播消息
    func broadcast(_ message: IPCMessage) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        var packet = data
        packet.append(0x0A) // 换行分隔符

        queue.async { [weak self] in
            guard let self else { return }
            for (fd, _) in self.clientSources {
                packet.withUnsafeBytes { ptr in
                    _ = write(fd, ptr.baseAddress, packet.count)
                }
            }
        }
    }

    /// 向指定客户端发送消息
    func send(_ message: IPCMessage, to clientFd: Int32) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        var packet = data
        packet.append(0x0A)

        queue.async {
            packet.withUnsafeBytes { ptr in
                _ = write(clientFd, ptr.baseAddress, packet.count)
            }
        }
    }
}

// MARK: - 客户端（运行在 G9NVibe 控制台 UI 中）

final class VibeIPCClient {
    private let socketPath: String
    private var clientFd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var receiveBuffer = Data()
    private let queue = DispatchQueue(label: "io.github.g9n9n-vibe.ipc.client", qos: .userInteractive)

    var onMessageReceived: ((IPCMessage) -> Void)?
    var onConnectionStatusChanged: ((Bool) -> Void)?

    private(set) var isConnected: Bool = false

    init(socketPath: String = VibeIPCConstants.socketPath) {
        self.socketPath = socketPath
    }

    deinit {
        disconnect()
    }

    func connect() -> Bool {
        disconnect()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { ptr in
            _ = strncpy(&addr.sun_path.0, ptr, maxLen - 1)
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, addrLen)
            }
        }

        guard connectResult == 0 else {
            close(fd)
            return false
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        self.clientFd = fd
        self.isConnected = true

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readIncomingData()
        }
        source.setCancelHandler { [weak self] in
            close(fd)
            self?.isConnected = false
            self?.onConnectionStatusChanged?(false)
        }
        source.resume()
        self.readSource = source

        onConnectionStatusChanged?(true)
        return true
    }

    func disconnect() {
        readSource?.cancel()
        readSource = nil
        clientFd = -1
        isConnected = false
        receiveBuffer.removeAll()
    }

    func send(_ message: IPCMessage) {
        guard isConnected, clientFd >= 0 else { return }
        guard let data = try? JSONEncoder().encode(message) else { return }
        var packet = data
        packet.append(0x0A)

        queue.async { [weak self] in
            guard let self, self.clientFd >= 0 else { return }
            packet.withUnsafeBytes { ptr in
                _ = write(self.clientFd, ptr.baseAddress, packet.count)
            }
        }
    }

    private func readIncomingData() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(clientFd, &buffer, buffer.count)
            if bytesRead > 0 {
                receiveBuffer.append(buffer, count: bytesRead)
            } else if bytesRead == 0 {
                disconnect()
                break
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                }
                disconnect()
                break
            }
        }

        while let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) {
            let lineData = receiveBuffer.subdata(in: 0..<newlineIndex)
            receiveBuffer.removeSubrange(0...newlineIndex)
            if !lineData.isEmpty {
                if let msg = try? JSONDecoder().decode(IPCMessage.self, from: lineData) {
                    DispatchQueue.main.async { [weak self] in
                        self?.onMessageReceived?(msg)
                    }
                }
            }
        }
    }
}
