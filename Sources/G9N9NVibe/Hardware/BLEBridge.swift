import CoreBluetooth
import Foundation

/// 遥控器开麦请求结果
enum RemoteMicrophoneOpenResult: Equatable {
    case sent
    case alreadyStreaming
    case retryAfter(TimeInterval)
    case unavailable
    case failed(String)
}

/// Google Chromecast (G9N9N) 专属 BLE ATVV 桥接器
/// 核心设计：控制面（接收按键手势 AUDIO_START / AUDIO_STOP）与音频面（ADPCM 解码推流）解耦，
/// 免驱或无需遥控器音频时自动跳过解码以节省 CPU 与电量。
final class BLEBridge: NSObject {
    static let serviceUUID = CBUUID(string: ATVVProtocol.serviceUUID)
    static let commandUUID = CBUUID(string: ATVVProtocol.txUUID)
    static let audioUUID   = CBUUID(string: ATVVProtocol.rxUUID)
    static let controlUUID = CBUUID(string: ATVVProtocol.controlUUID)
    /// 标准蓝牙 GATT 电池服务（用于读取 G9N9N 两节 7 号电池真实硬件电量）
    static let batteryServiceUUID = CBUUID(string: "180F")
    static let batteryLevelUUID   = CBUUID(string: "2A19")

    /// 外部查询当前是否需要解码并消费遥控器音频流（仅电脑麦模式返回 false 以省电省内存）
    var shouldConsumeRemoteAudio: (() -> Bool)?
    /// 消费解码后的 16kHz / 8kHz 单声道 Int16 PCM 采样
    var onDecodedSamples: (([Int16], Double) -> Void)?
    /// 原始 ATVV 会话边沿事件：reason 0x03 为物理按下，0x02 为物理松开
    var onAudioStarted: ((UInt8, Int) -> Void)?
    var onAudioStopped: ((UInt8) -> Void)?
    var onFirstAudioFrame: (() -> Void)?
    var onMicrophoneOpenFailed: ((UInt16) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?
    var onBluetoothAuthorizationChanged: ((CBManagerAuthorization) -> Void)?
    /// 遥控器真实硬件电量百分比（0...100；未连或固件不支持时为 nil）
    var onBatteryLevelChanged: ((Int?) -> Void)?
    /// 遥控器麦克风实时电平（dBFS，范围 -120...0）
    var onLevel: ((Double) -> Void)?
    /// 当前灵敏度线性增益（内存中同步，避免每 60ms 读一次 UserDefaults）
    var remoteGain: Float = AppStorage.remoteMicGainPreset.linearGain

    private var central: CBCentralManager!
    private var isStarted = false
    private var peripheral: CBPeripheral?
    private var audioChar: CBCharacteristic?
    private var commandChar: CBCharacteristic?
    private var controlChar: CBCharacteristic?
    private var batteryChar: CBCharacteristic?
    private var atvvCharsComplete = false
    private var connectTimeout: DispatchWorkItem?
    private var connectedPollTimer: Timer?
    private var keepAliveTimer: Timer?
    private var closeTimeoutWorkItem: DispatchWorkItem?

    private let protocolHandler = ATVVProtocol()
    private var streamID: UInt8 = 0
    private var isStreaming = false
    private var streamFrameCount = 0
    private var lastMicOpenAt = Date.distantPast
    private var lastStartSearchAt = Date.distantPast
    private var levelSumSq: Double = 0
    private var levelCount = 0
    private var levelPublishedAt = Date.distantPast

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isConnected: Bool {
        peripheral?.state == .connected && atvvCharsComplete
    }

    var bluetoothAuthorization: CBManagerAuthorization {
        CBManager.authorization
    }

    func start() {
        isStarted = true
        onBluetoothAuthorizationChanged?(CBManager.authorization)
        if central.state == .poweredOn {
            tryDirectConnect()
        } else {
            AppLog.write("CAST-BLE", "等待蓝牙状态就绪…")
        }
    }

    func stop() {
        isStarted = false
        stopConnectedPoll()
        stopKeepAliveTimer()
        closeTimeoutWorkItem?.cancel()
        closeTimeoutWorkItem = nil
        if isStreaming {
            if let closeCmd = try? protocolHandler.micCloseCommand(streamID: streamID) {
                writeCommand(closeCmd)
            }
            finishAudioStreamLocally(reason: 0xFD)
        }
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        audioChar = nil
        commandChar = nil
        controlChar = nil
        batteryChar = nil
        atvvCharsComplete = false
        onBatteryLevelChanged?(nil)
    }

    @discardableResult
    func openMicrophone(bypassDebounce: Bool = false) -> RemoteMicrophoneOpenResult {
        guard !isStreaming else { return .alreadyStreaming }
        guard peripheral != nil, commandChar != nil else {
            return .retryAfter(0.15)
        }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastMicOpenAt)
        guard bypassDebounce || elapsed >= 0.35 else {
            return .retryAfter(max(0.01, 0.35 - elapsed))
        }
        do {
            protocolHandler.prepareForAudioStream()
            guard writeCommand(try protocolHandler.micOpenCommand()) else {
                return .retryAfter(0.15)
            }
            lastMicOpenAt = now
            AppLog.write("CAST-BLE", "发送 MIC_OPEN 请求")
            return .sent
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func closeMicrophone(force: Bool = false) {
        guard force || isStreaming else { return }
        if !isStreaming {
            onLevel?(-120)
        }
        stopKeepAliveTimer()
        do {
            writeCommand(try protocolHandler.micCloseCommand(streamID: streamID))
            AppLog.write("CAST-BLE", "发送 MIC_CLOSE 请求")
            closeTimeoutWorkItem?.cancel()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.isStreaming else { return }
                AppLog.write("CAST-BLE", "等待 AUDIO_STOP 超时，强制本地收尾")
                self.finishAudioStreamLocally(reason: 0xFE)
            }
            closeTimeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: timeout)
        } catch {
            AppLog.write("CAST-BLE", "发送 MIC_CLOSE 失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 连接与发现

    private func tryDirectConnect() {
        guard isStarted, central.state == .poweredOn else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
        if let candidate = connected.first(where: matchesChromecast) {
            AppLog.write("CAST-BLE", "发现已连接 G9N9N 外设，直接建连: \(candidate.name ?? "Chromecast")")
            connect(to: candidate)
            return
        }

        if let saved = AppStorage.savedPeripheralUUID,
           let uuid = UUID(uuidString: saved),
           let known = central.retrievePeripherals(withIdentifiers: [uuid]).first,
           matchesChromecast(known) {
            AppLog.write("CAST-BLE", "通过缓存 UUID 重连 G9N9N: \(uuid.uuidString)")
            connect(to: known)
            return
        }

        startScan()
    }

    private func startScan() {
        guard isStarted, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        startConnectedPoll()
    }

    private func startConnectedPoll() {
        guard connectedPollTimer == nil else { return }
        // 已在系统蓝牙配对为 HID 的 G9N9N 不会持续发广播，需要轻量轮询 retrieveConnectedPeripherals
        connectedPollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self, self.isStarted, self.peripheral == nil, self.central.state == .poweredOn else { return }
            let connected = self.central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
            if let candidate = connected.first(where: self.matchesChromecast) {
                self.connect(to: candidate)
            }
        }
    }

    private func stopConnectedPoll() {
        connectedPollTimer?.invalidate()
        connectedPollTimer = nil
    }

    private func connect(to target: CBPeripheral) {
        stopConnectedPoll()
        central.stopScan()
        connectTimeout?.cancel()

        peripheral = target
        target.delegate = self
        central.connect(target, options: nil)

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.peripheral?.identifier == target.identifier, !self.atvvCharsComplete else { return }
            AppLog.write("CAST-BLE", "建连超时，重新扫描")
            self.central.cancelPeripheralConnection(target)
            self.peripheral = nil
            self.startScan()
        }
        connectTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: timeout)
    }

    private func matchesChromecast(_ p: CBPeripheral) -> Bool {
        guard let name = p.name?.lowercased(), !name.isEmpty else {
            return true
        }
        // 排除 X6 等其他型号，定向匹配 Chromecast / G9N9N 遥控器
        if name.contains("x6") { return false }
        return name.contains("chromecast") || name.contains("google") || name.contains("g9n9n") || name.contains("remote")
    }

    @discardableResult
    private func writeCommand(_ data: Data) -> Bool {
        guard let peripheral, let commandChar else { return false }
        let writeType: CBCharacteristicWriteType = commandChar.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        peripheral.writeValue(data, for: commandChar, type: writeType)
        return true
    }

    private func startKeepAliveTimer() {
        stopKeepAliveTimer()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self, self.isStreaming else { return }
            if let cmd = try? self.protocolHandler.keepAliveCommand(streamID: self.streamID) {
                self.writeCommand(cmd)
            }
        }
    }

    private func stopKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    private func finishAudioStreamLocally(reason: UInt8) {
        guard isStreaming else { return }
        isStreaming = false
        stopKeepAliveTimer()
        closeTimeoutWorkItem?.cancel()
        closeTimeoutWorkItem = nil
        protocolHandler.endAudioStream()
        levelSumSq = 0
        levelCount = 0
        onLevel?(-120)
        onAudioStopped?(reason)
    }
}

extension BLEBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onBluetoothAuthorizationChanged?(CBManager.authorization)
        switch central.state {
        case .poweredOn:
            if isStarted { tryDirectConnect() }
        default:
            if isStreaming { finishAudioStreamLocally(reason: 0xFC) }
            stopConnectedPoll()
            stopKeepAliveTimer()
            connectTimeout?.cancel()
            connectTimeout = nil
            if let peripheral {
                central.cancelPeripheralConnection(peripheral)
            }
            peripheral = nil
            audioChar = nil
            commandChar = nil
            controlChar = nil
            batteryChar = nil
            atvvCharsComplete = false
            onBatteryLevelChanged?(nil)
            onConnectionChanged?(false)
        }
    }

    /// 系统休眠唤醒（Wake）或从睡眠恢复时的重连入口
    func wakeRecover() {
        guard isStarted else { return }
        AppLog.write("CAST-BLE", "系统唤醒，主动检查并尝试重连 G9N9N 遥控器")
        if central.state == .poweredOn {
            if peripheral == nil || !isConnected {
                tryDirectConnect()
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard self.peripheral == nil, matchesChromecast(peripheral) else { return }
        AppLog.write("CAST-BLE", "扫描发现 G9N9N: \(peripheral.name ?? "Unknown") RSSI=\(RSSI)")
        connect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectTimeout?.cancel()
        connectTimeout = nil
        AppStorage.savedPeripheralUUID = peripheral.identifier.uuidString
        AppLog.write("CAST-BLE", "BLE 已连接，发现 ATVV 与电池服务")
        peripheral.discoverServices([Self.serviceUUID, Self.batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectTimeout?.cancel()
        self.peripheral = nil
        atvvCharsComplete = false
        onConnectionChanged?(false)
        if isStarted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.startScan()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectTimeout?.cancel()
        if isStreaming { finishAudioStreamLocally(reason: 0xFB) }
        self.peripheral = nil
        audioChar = nil
        commandChar = nil
        controlChar = nil
        batteryChar = nil
        atvvCharsComplete = false
        onBatteryLevelChanged?(nil)
        onConnectionChanged?(false)
        AppLog.write("CAST-BLE", "BLE 连接已断开，准备自动重连")
        if isStarted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.tryDirectConnect()
            }
        }
    }
}

extension BLEBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }
        for service in services {
            if service.uuid == Self.serviceUUID {
                peripheral.discoverCharacteristics([Self.commandUUID, Self.audioUUID, Self.controlUUID], for: service)
            } else if service.uuid == Self.batteryServiceUUID {
                peripheral.discoverCharacteristics([Self.batteryLevelUUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let chars = service.characteristics else { return }
        if service.uuid == Self.batteryServiceUUID {
            if let char = chars.first(where: { $0.uuid == Self.batteryLevelUUID }) {
                batteryChar = char
                peripheral.readValue(for: char)
                if char.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: char)
                }
            }
            return
        }
        for char in chars {
            switch char.uuid {
            case Self.commandUUID:
                commandChar = char
            case Self.audioUUID:
                audioChar = char
                peripheral.setNotifyValue(true, for: char)
            case Self.controlUUID:
                controlChar = char
                peripheral.setNotifyValue(true, for: char)
            default:
                break
            }
        }
        if commandChar != nil, audioChar != nil, controlChar != nil, !atvvCharsComplete {
            atvvCharsComplete = true
            onConnectionChanged?(true)
            writeCommand(protocolHandler.getCapabilitiesCommand)
            AppLog.write("CAST-BLE", "ATVV 特征值就绪，已请求能力协商")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }

        if characteristic.uuid == Self.controlUUID {
            handleControlPacket(data)
        } else if characteristic.uuid == Self.audioUUID {
            handleAudioPacket(data)
        } else if characteristic.uuid == Self.batteryLevelUUID, let rawByte = data.first {
            let pct = min(100, Int(rawByte))
            AppLog.write("CAST-BLE", "G9N9N 硬件电量: \(pct)%")
            onBatteryLevelChanged?(pct)
        }
    }

    private func handleControlPacket(_ data: Data) {
        let event = protocolHandler.parseControl(data)
        switch event {
        case .capabilities(let caps):
            do {
                try protocolHandler.acceptCapabilities(caps)
                AppLog.write("CAST-BLE", "ATVV 协商完成: v\(caps.version) codec=\(caps.selectedCodec?.description ?? "none")")
            } catch {
                AppLog.write("CAST-BLE", "ATVV 能力协商失败: \(error.localizedDescription)")
            }

        case .startSearch:
            let now = Date()
            guard now.timeIntervalSince(lastStartSearchAt) >= 0.25 else { return }
            lastStartSearchAt = now
            // 始终响应 MIC_OPEN 保证兼容版遥控器正常上送松手事件 AUDIO_STOP(0x02)
            _ = openMicrophone(bypassDebounce: true)

        case .audioStart(let reason, let codec, let id):
            closeTimeoutWorkItem?.cancel()
            closeTimeoutWorkItem = nil
            streamID = id
            isStreaming = true
            streamFrameCount = 0
            protocolHandler.beginAudioStream(codec: codec)
            startKeepAliveTimer()
            AppLog.write("CAST-BLE", "AUDIO_START reason=0x\(String(format: "%02X", reason)) rate=\(codec.sampleRate)")
            onAudioStarted?(reason, codec.sampleRate)

        case .audioStop(let reason):
            AppLog.write("CAST-BLE", "AUDIO_STOP reason=0x\(String(format: "%02X", reason))")
            finishAudioStreamLocally(reason: reason)

        case .audioSync(let codec, let seq, let predictor, let stepIndex):
            protocolHandler.applyAudioSync(codec: codec, sequence: seq, predictor: predictor, stepIndex: stepIndex)

        case .micOpenError(let code):
            AppLog.write("CAST-BLE", "MIC_OPEN 错误: 0x\(String(format: "%04X", code))")
            onMicrophoneOpenFailed?(code)

        case .unknown:
            break
        }
    }

    private func handleAudioPacket(_ data: Data) {
        guard isStreaming else { return }
        if streamFrameCount == 0 {
            streamFrameCount = 1
            onFirstAudioFrame?()
        } else {
            streamFrameCount += 1
        }

        // 控制面与音频面解耦：免驱或不需要遥控器音频时直接跳过 ADPCM 解码，零 CPU 损耗
        guard shouldConsumeRemoteAudio?() ?? true else { return }
        guard let decoded = protocolHandler.decodeAudio(data), !decoded.samples.isEmpty else { return }

        let sampleRate = Double(protocolHandler.codec?.sampleRate ?? 16_000)
        onDecodedSamples?(decoded.samples, sampleRate)

        // 轻量实时电平计算（每 60ms 节流回调一次）
        for s in decoded.samples {
            let norm = Double(s) / 32768.0
            levelSumSq += norm * norm
            levelCount += 1
        }
        let now = Date()
        if now.timeIntervalSince(levelPublishedAt) >= 0.06, levelCount > 0 {
            let rms = sqrt(levelSumSq / Double(levelCount))
            // 叠加当前灵敏度增益档位，与实际输出电平保持一致
            let calibrated = min(1.0, rms * Double(remoteGain))
            let db = calibrated > 1e-5 ? max(-60.0, 20.0 * log10(calibrated)) : -120.0
            onLevel?(db)
            levelSumSq = 0
            levelCount = 0
            levelPublishedAt = now
        }
    }
}
