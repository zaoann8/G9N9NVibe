import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// 当前录音会话的物理触发来源（用于「智能随动」无冲突选通麦克风）
enum SessionTriggerSource: String, CaseIterable {
    case none
    case keyboard
    case remote
}

/// 音频路由与选通纯函数决策结果（全局唯一真相来源，供 AudioPipe、MicRouteCoordinator 与单元测试共用）
struct AudioRoutingDecision: Equatable {
    /// 虚拟声卡输出流是否混入 Mac 物理麦
    let useMacInVirtualOutput: Bool
    /// 虚拟声卡输出流是否混入遥控器 BLE 麦（同时决定 BLEBridge 是否解码 ADPCM）
    let useRemoteInVirtualOutput: Bool
    /// 是否需要运行虚拟声卡输出 IOProc
    let needsVirtualOutputIO: Bool
    /// 是否需要为 Mac 麦开启只读电平动效（免驱直通或「仅电脑麦」模式下）
    let needsDirectMacMeter: Bool
    /// Mac 路是否施加 120ms 缓冲对齐延迟（仅双麦合并时需要，其他模式严格 0ms）
    let applyDualMixDelay: Bool
    /// 跟随系统默认麦的输入法（微信/系统听写）此刻是否需要短暂切入虚拟声卡
    let needsTransientSystemRoute: Bool

    var needsMacCapture: Bool {
        useMacInVirtualOutput || needsDirectMacMeter
    }

    static func resolve(
        driverAvailable: Bool,
        allMuted: Bool,
        policy: MicRoutingPolicy,
        sessionActive: Bool,
        triggerSource: SessionTriggerSource,
        uiMeterVisible: Bool
    ) -> AudioRoutingDecision {
        guard !allMuted, sessionActive else {
            return AudioRoutingDecision(
                useMacInVirtualOutput: false,
                useRemoteInVirtualOutput: false,
                needsVirtualOutputIO: false,
                needsDirectMacMeter: false,
                applyDualMixDelay: false,
                needsTransientSystemRoute: false
            )
        }

        // 未装驱动或「仅电脑麦」直通态：绝不走虚拟声卡、绝不接管系统默认麦
        guard driverAvailable, policy.requiresDriver else {
            return AudioRoutingDecision(
                useMacInVirtualOutput: false,
                useRemoteInVirtualOutput: false,
                needsVirtualOutputIO: false,
                needsDirectMacMeter: uiMeterVisible,
                applyDualMixDelay: false,
                needsTransientSystemRoute: false
            )
        }

        switch policy {
        case .macOnly:
            return AudioRoutingDecision(
                useMacInVirtualOutput: false,
                useRemoteInVirtualOutput: false,
                needsVirtualOutputIO: false,
                needsDirectMacMeter: uiMeterVisible,
                applyDualMixDelay: false,
                needsTransientSystemRoute: false
            )
        case .smartByTriggerSource:
            // 核心「智能随动」防回声规则：遥控器触发仅通遥控器麦，键盘触发仅通电脑麦（两者严格互斥）
            let isRemote = (triggerSource == .remote)
            return AudioRoutingDecision(
                useMacInVirtualOutput: !isRemote,
                useRemoteInVirtualOutput: isRemote,
                needsVirtualOutputIO: true,
                needsDirectMacMeter: false,
                applyDualMixDelay: false,
                needsTransientSystemRoute: isRemote
            )
        case .remoteOnly:
            return AudioRoutingDecision(
                useMacInVirtualOutput: false,
                useRemoteInVirtualOutput: true,
                needsVirtualOutputIO: true,
                needsDirectMacMeter: false,
                applyDualMixDelay: false,
                needsTransientSystemRoute: true
            )
        case .dualMix:
            return AudioRoutingDecision(
                useMacInVirtualOutput: true,
                useRemoteInVirtualOutput: true,
                needsVirtualOutputIO: true,
                needsDirectMacMeter: false,
                applyDualMixDelay: true,
                needsTransientSystemRoute: true
            )
        }
    }
}

/// 极低内存双麦克风路由与混音管线：
/// - 免驱态：彻底休眠，不启动 AVCaptureSession 也不挂 CoreAudio IO（零音频内存占用）
/// - 驱动态：严格按会话按需启停 Mac 物理麦采集（防止常亮橙灯与 AirPods 蓝牙音质降级）
/// - 实时 IO 回调全程使用预分配 FloatRingBuffer（Zero-Allocation），支持 0ms 透传与 120ms 双麦对齐
final class AudioPipe: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let shared = AudioPipe()

    private static let outputSampleRate: Double = 48_000
    private static let dualMixDelayFrames = Int(48_000 * 0.12) // 双麦合并时 120ms 对齐缓冲

    private let stateLock = NSLock()
    private let captureQueue = DispatchQueue(label: "io.github.g9n9n-vibe.capture", qos: .userInteractive)

    // 预分配固定环形缓冲与单声道临时复用缓冲（全程零运行时堆分配）
    private let macRing = FloatRingBuffer(capacity: 32_768)
    private let remoteRing = FloatRingBuffer(capacity: 32_768)
    private var monoScratch = [Float](repeating: 0, count: 4096)
    /// 遥控器蓝牙麦实时 DSP 增益（支持近场 +14dB / 标准 +20dB / 远场 +26dB 动态热切换）
    private var remoteGain: Float = AppStorage.remoteMicGainPreset.linearGain

    private var captureSession: AVCaptureSession?
    private var captureRunning = false
    private var idleStopWorkItem: DispatchWorkItem?
    private var outputIdleStopWorkItem: DispatchWorkItem?

    private var outputDeviceID: AudioDeviceID?
    private var outputIOProcID: AudioDeviceIOProcID?
    private var outputRunning = false

    private var sessionActive = false
    private var activeTriggerSource: SessionTriggerSource = .none
    private var policy: MicRoutingPolicy = AppStorage.micPolicy
    private var driverAvailable = false
    private var uiPreviewEnabled = false
    private var allMuted = false
    private var smoothedMacDb: Double = -120

    // 电平节流回调（仅在 UI 窗口打开时由外部绑定，关窗时置空零开销）
    var onMacLevel: ((Double) -> Void)?
    var onOutputLevel: ((Double) -> Void)?
    private var lastMacLevelAt = Date.distantPast
    private var lastOutLevelAt = Date.distantPast

    private override init() {
        super.init()
    }

    var isDriverOutputRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return outputIOProcID != nil
    }

    /// 驱动安装、卸载或 coreaudiod 重启后重建音频管道
    func rebuildAfterDriverChange(driverAvailable: Bool, policy: MicRoutingPolicy) {
        stopOutputDevice()
        stopCaptureImmediately()

        stateLock.lock()
        self.driverAvailable = driverAvailable
        self.policy = policy
        let active = sessionActive
        let source = activeTriggerSource
        let preview = uiPreviewEnabled
        macRing.reset()
        remoteRing.reset()
        stateLock.unlock()

        if driverAvailable, let deviceID = MicRouteCoordinator.virtualMicDeviceID() {
            prepareOutputDevice(deviceID)
        } else {
            AppLog.write("AUDIO-PIPE", "驱动未安装或不可用，音频路由保持免驱直通态")
        }
        if active {
            syncCaptureLifecycle(active: active, source: source, policy: policy, driverAvailable: driverAvailable, previewEnabled: preview, immediateStop: false)
            syncOutputLifecycle(active: active, policy: policy, driverAvailable: driverAvailable)
        }
    }

    func updatePolicy(_ newPolicy: MicRoutingPolicy) {
        stateLock.lock()
        policy = newPolicy
        let active = sessionActive
        let source = activeTriggerSource
        let hasDriver = driverAvailable
        let preview = uiPreviewEnabled
        stateLock.unlock()

        syncCaptureLifecycle(active: active, source: source, policy: newPolicy, driverAvailable: hasDriver, previewEnabled: preview, immediateStop: !active)
        syncOutputLifecycle(active: active, policy: newPolicy, driverAvailable: hasDriver)
    }

    /// 双麦全部静音开关（开启全部静音后立即停止一切采麦与虚拟输出 IO，绝不占用系统资源）
    func setAllMuted(_ muted: Bool) {
        stateLock.lock()
        allMuted = muted
        let active = sessionActive
        let source = activeTriggerSource
        let curPolicy = policy
        let hasDriver = driverAvailable
        let preview = uiPreviewEnabled
        if muted {
            smoothedMacDb = -120
            macRing.reset()
            remoteRing.reset()
        }
        stateLock.unlock()

        if muted {
            stopCaptureImmediately()
            stopOutputIOImmediately()
            DispatchQueue.main.async { [weak self] in
                self?.onMacLevel?(-120)
                self?.onOutputLevel?(-120)
            }
        } else if active {
            syncCaptureLifecycle(active: active, source: source, policy: curPolicy, driverAvailable: hasDriver, previewEnabled: preview, immediateStop: false)
            syncOutputLifecycle(active: active, policy: curPolicy, driverAvailable: hasDriver)
        }
    }

    /// 控制台「音频」页面可见性与 Mac 麦开关状态同步：
    /// 严格遵循「仅录音时采集」原则——待机不占麦克风、不亮橙灯；仅在会话激活期间且此标志为 true 时亮起微光柱
    func setUIPreviewEnabled(_ enabled: Bool) {
        stateLock.lock()
        uiPreviewEnabled = enabled
        let active = sessionActive
        let source = activeTriggerSource
        let curPolicy = policy
        let hasDriver = driverAvailable
        if !enabled {
            smoothedMacDb = -120
        }
        stateLock.unlock()

        syncCaptureLifecycle(active: active, source: source, policy: curPolicy, driverAvailable: hasDriver, previewEnabled: enabled, immediateStop: true)
        if !enabled || !active {
            DispatchQueue.main.async { [weak self] in
                self?.onMacLevel?(-120)
                self?.onOutputLevel?(-120)
            }
        }
    }

    /// 会话状态变更入口（由 VoiceSessionCoordinator 或试说测试调用）
    func setSessionActive(_ active: Bool, triggerSource: SessionTriggerSource) {
        stateLock.lock()
        let sourceChanged = (activeTriggerSource != (active ? triggerSource : .none))
        sessionActive = active
        activeTriggerSource = active ? triggerSource : .none
        let currentPolicy = policy
        let hasDriver = driverAvailable
        let preview = uiPreviewEnabled
        if !active || sourceChanged {
            // 结束会话或切换触发源时同时清空两路环形缓冲，彻底杜绝旧尾音串入下一次说话
            macRing.reset()
            remoteRing.reset()
            if !active {
                smoothedMacDb = -120
            }
        }
        stateLock.unlock()

        // 免驱模式下结束录音立即释放采集会话，零延迟熄灭橙灯；驱动态短延迟避免连续说话频繁开关设备
        let effectiveSource: SessionTriggerSource = active ? triggerSource : .none
        syncCaptureLifecycle(
            active: active,
            source: effectiveSource,
            policy: currentPolicy,
            driverAvailable: hasDriver,
            previewEnabled: preview,
            immediateStop: !hasDriver
        )
        syncOutputLifecycle(active: active, policy: currentPolicy, driverAvailable: hasDriver)
        if !active {
            DispatchQueue.main.async { [weak self] in
                self?.onMacLevel?(-120)
                self?.onOutputLevel?(-120)
            }
        }
    }

    /// 查询当前策略与会话是否需要消费遥控器音频（供 BLEBridge 跳过无用 ADPCM 解码）
    func shouldAcceptRemoteAudio() -> Bool {
        stateLock.lock()
        let decision = AudioRoutingDecision.resolve(
            driverAvailable: driverAvailable,
            allMuted: allMuted,
            policy: policy,
            sessionActive: sessionActive,
            triggerSource: activeTriggerSource,
            uiMeterVisible: uiPreviewEnabled
        )
        stateLock.unlock()
        return decision.useRemoteInVirtualOutput
    }

    /// 实时切换遥控器收音灵敏度档位（热生效，无需重启驱动或音频管线）
    func setRemoteGainPreset(_ preset: RemoteMicGainPreset) {
        stateLock.lock()
        remoteGain = preset.linearGain
        stateLock.unlock()
        AppLog.write("AUDIO-PIPE", "遥控器灵敏度已调整为 \(preset.title(lang: .zh)) (\(preset.dbLabel))")
    }

    /// 写入解码后的遥控器单声道 PCM（由 BLEBridge 回调）
    func feedRemote(samples: [Int16], inputSampleRate: Double) {
        guard !samples.isEmpty, shouldAcceptRemoteAudio() else { return }
        let ratio = Self.outputSampleRate / max(8_000, inputSampleRate)

        stateLock.lock()
        defer { stateLock.unlock() }
        let gain = remoteGain
        // 轻度软限幅：常规人声线性透明，远场高增益下大声说话不产生刺耳硬削波
        @inline(__always)
        func softLimit(_ x: Float) -> Float {
            if abs(x) <= 0.85 { return x }
            return tanhf(x)
        }
        // 线性插值上采样至 48kHz 并直接压入预分配环形缓冲（零临时数组）
        if samples.count == 1 {
            let v = softLimit(Float(samples[0]) / 32768.0 * gain)
            let repeats = max(1, Int(ratio.rounded()))
            for _ in 0..<repeats { remoteRing.push(v) }
            return
        }
        let outCount = Int(Double(samples.count) * ratio)
        let invRatio = 1.0 / ratio
        for i in 0..<outCount {
            let srcPos = Double(i) * invRatio
            let idx = Int(srcPos)
            let frac = Float(srcPos - Double(idx))
            let s0 = Float(samples[min(idx, samples.count - 1)]) / 32768.0 * gain
            let s1 = Float(samples[min(idx + 1, samples.count - 1)]) / 32768.0 * gain
            let sample = softLimit(s0 + (s1 - s0) * frac)
            remoteRing.push(sample)
        }
        // 控制最大积压不超过 0.35 秒，防止延迟累积
        let maxFrames = Int(Self.outputSampleRate * 0.35)
        if remoteRing.count > maxFrames {
            remoteRing.dropOldest(remoteRing.count - maxFrames)
        }
    }

    func shutdown() {
        stopCaptureImmediately()
        stopOutputDevice()
    }

    // MARK: - 按需启停 Mac 物理麦克风采集（保护 AirPods 音质与极低内存）

    private func syncCaptureLifecycle(
        active: Bool,
        source: SessionTriggerSource,
        policy: MicRoutingPolicy,
        driverAvailable: Bool,
        previewEnabled: Bool,
        immediateStop: Bool
    ) {
        stateLock.lock()
        let muted = allMuted
        stateLock.unlock()

        // 严格复用唯一真相决策函数 AudioRoutingDecision.resolve，杜绝逻辑分叉；待机绝不占麦、不亮橙灯
        let decision = AudioRoutingDecision.resolve(
            driverAvailable: driverAvailable,
            allMuted: muted,
            policy: policy,
            sessionActive: active,
            triggerSource: source,
            uiMeterVisible: previewEnabled
        )

        if decision.needsMacCapture {
            idleStopWorkItem?.cancel()
            idleStopWorkItem = nil
            startCaptureIfNeeded()
        } else if immediateStop || !driverAvailable || muted {
            stopCaptureImmediately()
        } else {
            scheduleIdleCaptureStop()
        }
    }

    private func startCaptureIfNeeded() {
        captureQueue.async { [weak self] in
            guard let self, !self.captureRunning else { return }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                AppLog.write("AUDIO-PIPE", "缺少麦克风权限，跳过 Mac 物理麦采集")
                return
            }

            if self.captureSession == nil {
                guard let session = self.buildCaptureSession() else { return }
                self.captureSession = session
            }
            self.captureSession?.startRunning()
            self.captureRunning = true
            AppLog.write("AUDIO-PIPE", "按需启动 Mac 物理麦采集")
        }
    }

    private func scheduleIdleCaptureStop() {
        idleStopWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.stopCaptureImmediately()
        }
        idleStopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func stopCaptureImmediately() {
        idleStopWorkItem?.cancel()
        idleStopWorkItem = nil
        captureQueue.async { [weak self] in
            guard let self else { return }
            if self.captureRunning {
                self.captureSession?.stopRunning()
                self.captureRunning = false
                AppLog.write("AUDIO-PIPE", "空闲释放 Mac 物理麦采集（释放橙灯与蓝牙通话通道）")
            }
            // 彻底释放 AVCaptureSession 释放内存
            self.captureSession = nil
            self.stateLock.lock()
            self.macRing.reset()
            self.stateLock.unlock()
        }
    }

    private func buildCaptureSession() -> AVCaptureSession? {
        // 严格过滤排除自身虚拟驱动，杜绝自采啸叫死循环
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        let physicalDevices = discovery.devices.filter {
            $0.uniqueID != AppStorage.virtualDriverDeviceUID &&
            $0.localizedName != AppStorage.virtualDriverDeviceName
        }

        // 优先匹配系统当前正在使用的物理默认麦（支持 AirPods / USB 麦 / 内置麦自动跟随）
        var targetDevice: AVCaptureDevice?
        if let defaultID = MicRouteCoordinator.defaultInputDeviceID(),
           let defaultUID = MicRouteCoordinator.deviceUID(for: defaultID),
           defaultUID != AppStorage.virtualDriverDeviceUID {
            targetDevice = physicalDevices.first(where: { $0.uniqueID == defaultUID })
        }
        if targetDevice == nil {
            if #available(macOS 14.0, *) {
                targetDevice = physicalDevices.first(where: { $0.deviceType == .microphone }) ?? physicalDevices.first
            } else {
                targetDevice = physicalDevices.first(where: { $0.deviceType == .builtInMicrophone }) ?? physicalDevices.first
            }
        }

        guard let device = targetDevice else {
            AppLog.write("AUDIO-PIPE", "未找到可用的 Mac 物理麦克风")
            return nil
        }

        let session = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return nil }
            session.addInput(input)

            let output = AVCaptureAudioDataOutput()
            // 不强制覆写 audioSettings，直接接收设备原生 PCM 流并在回调里自适应解码，彻底避免 macOS 15 硬件麦格式不兼容导致静音
            output.setSampleBufferDelegate(self, queue: captureQueue)
            guard session.canAddOutput(output) else { return nil }
            session.addOutput(output)
            AppLog.write("AUDIO-PIPE", "已绑定物理麦克风采集源: \(device.localizedName)")
            return session
        } catch {
            AppLog.write("AUDIO-PIPE", "创建 Mac 麦采集会话失败: \(error.localizedDescription)")
            return nil
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }
        let asbd = asbdPtr.pointee
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        // 使用标准 AudioBufferList 读取，兼容交错 / 非交错、Float32 / Int16 / Int32 任意硬件原生格式
        var blockBuffer: CMBlockBuffer?
        var listSizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard listSizeNeeded > 0 else { return }
        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: listSizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawList.deallocate() }
        let ablPtr = rawList.assumingMemoryBound(to: AudioBufferList.self)
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: listSizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        guard let firstBuf = buffers.first, let mData = firstBuf.mData, firstBuf.mDataByteSize > 0 else { return }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channelsInFirstBuf = isNonInterleaved ? 1 : max(1, Int(asbd.mChannelsPerFrame))
        let bits = Int(asbd.mBitsPerChannel)

        // 复用预分配单声道缓冲，零实时堆分配
        if monoScratch.count < frameCount {
            monoScratch = [Float](repeating: 0, count: frameCount)
        }
        var sumSq: Double = 0
        var validFrames = 0

        if isFloat && bits == 32 {
            let totalFloats = Int(firstBuf.mDataByteSize) / MemoryLayout<Float>.size
            validFrames = min(frameCount, totalFloats / channelsInFirstBuf)
            let fPtr = mData.assumingMemoryBound(to: Float.self)
            for i in 0..<validFrames {
                let v = fPtr[i * channelsInFirstBuf]
                monoScratch[i] = v
                sumSq += Double(v) * Double(v)
            }
        } else if !isFloat && bits == 16 {
            let totalSamples = Int(firstBuf.mDataByteSize) / MemoryLayout<Int16>.size
            validFrames = min(frameCount, totalSamples / channelsInFirstBuf)
            let iPtr = mData.assumingMemoryBound(to: Int16.self)
            for i in 0..<validFrames {
                let v = Float(iPtr[i * channelsInFirstBuf]) / 32768.0
                monoScratch[i] = v
                sumSq += Double(v) * Double(v)
            }
        } else if !isFloat && bits == 32 {
            let totalSamples = Int(firstBuf.mDataByteSize) / MemoryLayout<Int32>.size
            validFrames = min(frameCount, totalSamples / channelsInFirstBuf)
            let iPtr = mData.assumingMemoryBound(to: Int32.self)
            for i in 0..<validFrames {
                let v = Float(Double(iPtr[i * channelsInFirstBuf]) / 2_147_483_648.0)
                monoScratch[i] = v
                sumSq += Double(v) * Double(v)
            }
        } else {
            return
        }

        stateLock.lock()
        let isActiveSession = sessionActive && !allMuted
        let writeToRing = driverAvailable && policy.requiresDriver && isActiveSession
        let mirrorOutput = (!driverAvailable || !policy.requiresDriver) && isActiveSession
        if writeToRing && validFrames > 0 {
            let inRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : Self.outputSampleRate
            if abs(inRate - Self.outputSampleRate) < 1.0 {
                for i in 0..<validFrames {
                    macRing.push(monoScratch[i])
                }
            } else {
                // 任意采样率硬件麦（如 16kHz AirPods / 44.1kHz 外置麦）自动线性重采样至 48kHz
                let ratio = Self.outputSampleRate / inRate
                let outCount = max(1, Int(Double(validFrames) * ratio))
                let invRatio = 1.0 / ratio
                for i in 0..<outCount {
                    let pos = Double(i) * invRatio
                    let idx = Int(pos)
                    let frac = Float(pos - Double(idx))
                    let s0 = monoScratch[min(idx, validFrames - 1)]
                    let s1 = monoScratch[min(idx + 1, validFrames - 1)]
                    macRing.push(s0 + (s1 - s0) * frac)
                }
            }
            let maxFrames = Int(Self.outputSampleRate * 0.35)
            if macRing.count > maxFrames {
                macRing.dropOldest(macRing.count - maxFrames)
            }
        }
        stateLock.unlock()

        let now = Date()
        if isActiveSession, onMacLevel != nil, now.timeIntervalSince(lastMacLevelAt) >= 0.04 {
            lastMacLevelAt = now
            let rms = sqrt(sumSq / Double(max(1, frameCount)))
            let rawDb = rms > 1e-5 ? max(-60.0, 20.0 * log10(rms)) : -120.0
            // 快起慢落平滑（Attack 0.72 / Release 0.35），让 40 根声学微光柱跳动灵动跟手
            let smoothed: Double
            if rawDb > smoothedMacDb {
                smoothed = smoothedMacDb < -59 ? rawDb : (smoothedMacDb * 0.28 + rawDb * 0.72)
            } else {
                smoothed = rawDb < -59 ? max(-120.0, smoothedMacDb - 6.0) : (smoothedMacDb * 0.65 + rawDb * 0.35)
            }
            smoothedMacDb = smoothed < -58.5 ? -120.0 : smoothed
            let emitDb = smoothedMacDb
            DispatchQueue.main.async { [weak self] in
                self?.onMacLevel?(emitDb)
                if mirrorOutput {
                    self?.onOutputLevel?(emitDb)
                }
            }
        }
    }

    // MARK: - CoreAudio 驱动输出 IO（按需启停，待机彻底零空转节省 coreaudiod CPU）

    private func prepareOutputDevice(_ deviceID: AudioDeviceID) {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { [weak self] _, _, _, outOutputData, _ in
            self?.renderOutput(outOutputData)
        }
        guard status == noErr, let procID else {
            AppLog.write("AUDIO-PIPE", "创建虚拟声卡 IOProc 失败: \(status)")
            return
        }
        stateLock.lock()
        outputDeviceID = deviceID
        outputIOProcID = procID
        outputRunning = false
        stateLock.unlock()
        AppLog.write("AUDIO-PIPE", "虚拟声卡输出句柄已就绪（按需启停零空转，deviceID=\(deviceID)）")
    }

    private func syncOutputLifecycle(active: Bool, policy: MicRoutingPolicy, driverAvailable: Bool) {
        stateLock.lock()
        let muted = allMuted
        stateLock.unlock()

        if !muted && driverAvailable && active && policy.requiresDriver {
            outputIdleStopWorkItem?.cancel()
            outputIdleStopWorkItem = nil
            startOutputIOIfNeeded()
        } else if muted || !driverAvailable || !policy.requiresDriver {
            stopOutputIOImmediately()
        } else {
            outputIdleStopWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.stopOutputIOImmediately()
            }
            outputIdleStopWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        }
    }

    private func startOutputIOIfNeeded() {
        stateLock.lock()
        guard let devID = outputDeviceID, let procID = outputIOProcID, !outputRunning else {
            stateLock.unlock()
            return
        }
        outputRunning = true
        stateLock.unlock()

        let status = AudioDeviceStart(devID, procID)
        if status != noErr {
            stateLock.lock()
            outputRunning = false
            stateLock.unlock()
            AppLog.write("AUDIO-PIPE", "启动虚拟声卡输出失败: \(status)")
        }
    }

    private func stopOutputIOImmediately() {
        outputIdleStopWorkItem?.cancel()
        outputIdleStopWorkItem = nil
        stateLock.lock()
        guard let devID = outputDeviceID, let procID = outputIOProcID, outputRunning else {
            stateLock.unlock()
            return
        }
        outputRunning = false
        stateLock.unlock()
        AudioDeviceStop(devID, procID)
    }

    private func stopOutputDevice() {
        outputIdleStopWorkItem?.cancel()
        outputIdleStopWorkItem = nil
        stateLock.lock()
        let devID = outputDeviceID
        let procID = outputIOProcID
        let wasRunning = outputRunning
        outputDeviceID = nil
        outputIOProcID = nil
        outputRunning = false
        stateLock.unlock()

        if let devID, let procID {
            if wasRunning {
                AudioDeviceStop(devID, procID)
            }
            AudioDeviceDestroyIOProcID(devID, procID)
        }
    }

    private func renderOutput(_ bufferListPtr: UnsafeMutablePointer<AudioBufferList>) {
        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)
        guard let firstBuffer = bufferList.first, let rawData = firstBuffer.mData else { return }

        let channels = max(1, Int(firstBuffer.mNumberChannels))
        let totalFloats = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
        let frameCount = totalFloats / channels
        let outPtr = rawData.assumingMemoryBound(to: Float.self)

        stateLock.lock()
        let decision = AudioRoutingDecision.resolve(
            driverAvailable: driverAvailable,
            allMuted: allMuted,
            policy: policy,
            sessionActive: sessionActive,
            triggerSource: activeTriggerSource,
            uiMeterVisible: uiPreviewEnabled
        )

        guard decision.needsVirtualOutputIO else {
            stateLock.unlock()
            memset(rawData, 0, Int(firstBuffer.mDataByteSize))
            return
        }

        let useMac = decision.useMacInVirtualOutput
        let useRemote = decision.useRemoteInVirtualOutput

        // 双麦合并时保持 Mac 路 120ms 缓冲水位与 BLE 对齐；单独使用 Mac 路则 0ms 零延迟输出
        let allowMacPop = !decision.applyDualMixDelay || (macRing.count >= Self.dualMixDelayFrames)

        var sumSq: Float = 0
        for f in 0..<frameCount {
            let mSample: Float = (useMac && allowMacPop) ? (macRing.pop() ?? 0) : 0
            let rSample: Float = useRemote ? (remoteRing.pop() ?? 0) : 0

            let mixed: Float
            if useMac && useRemote {
                // 等权合并并软限幅防爆音
                mixed = max(-1.0, min(1.0, (mSample + rSample) * 0.72))
            } else {
                mixed = max(-1.0, min(1.0, mSample + rSample))
            }

            sumSq += mixed * mixed
            let base = f * channels
            for c in 0..<channels {
                outPtr[base + c] = mixed
            }
        }
        stateLock.unlock()

        let now = Date()
        if onOutputLevel != nil, now.timeIntervalSince(lastOutLevelAt) >= 0.06 {
            lastOutLevelAt = now
            let rms = sqrt(Double(sumSq) / Double(max(1, frameCount)))
            let db = rms > 1e-5 ? max(-60.0, 20.0 * log10(rms)) : -120.0
            DispatchQueue.main.async { [weak self] in
                self?.onOutputLevel?(db)
            }
        }
    }
}
