import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// 当前录音会话的物理触发来源（用于「智能随动」无冲突选通麦克风）
enum SessionTriggerSource: String, CaseIterable, Codable {
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
/// - 免驱态：彻底休眠，不启动 AudioQueue 也不挂 CoreAudio IO（零音频内存占用）
/// - 驱动态：严格按会话按需启停 Mac 物理麦采集（防止常亮橙灯与 AirPods 蓝牙音质降级）
/// - 采集层采用 AudioToolbox 原生 AudioQueue（11KB 极小双缓冲，零视频/媒体图依赖，关麦瞬间灭灯）
/// - 实时 IO 回调全程使用预分配 FloatRingBuffer（Zero-Allocation），支持 0ms 透传与 120ms 双麦对齐
final class AudioPipe: NSObject {
    static let shared = AudioPipe()

    private static let outputSampleRate: Double = 48_000
    private static let dualMixDelayFrames = Int(48_000 * 0.12) // 双麦合并时 120ms 对齐缓冲
    private static let kBufferFrameCount: UInt32 = 960 // 20ms @ 48kHz (3840 字节极小缓冲)

    private let stateLock = NSLock()
    private let captureQueue = DispatchQueue(label: "io.github.g9n9n-vibe.capture", qos: .userInteractive)

    // 预分配固定环形缓冲（全程零运行时堆分配）
    private let macRing = FloatRingBuffer(capacity: 32_768)
    private let remoteRing = FloatRingBuffer(capacity: 32_768)
    /// 双麦合并时 120ms 初始相位对齐延迟建立标志（防止每个 IOProc 周期因水位波动交替产生 512 帧音频与静音）
    private var macDelayPrimed = false
    /// 遥控器蓝牙麦实时 DSP 增益（支持近场 +14dB / 标准 +20dB / 远场 +26dB 动态热切换）
    private var remoteGain: Float = AppStorage.remoteMicGainPreset.linearGain

    private var audioQueue: AudioQueueRef?
    private var audioBuffers: [AudioQueueBufferRef?] = [nil, nil, nil]
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
        macDelayPrimed = false
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
            macDelayPrimed = false
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
            macDelayPrimed = false
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

    private static let inputCallback: AudioQueueInputCallback = { userData, inAQ, inBuffer, inStartTime, inNumPackets, inPacketDesc in
        guard let userData else { return }
        let pipe = Unmanaged<AudioPipe>.fromOpaque(userData).takeUnretainedValue()
        pipe.handleAudioQueueBuffer(inAQ: inAQ, inBuffer: inBuffer, numPackets: inNumPackets)
    }

    private func handleAudioQueueBuffer(inAQ: AudioQueueRef, inBuffer: AudioQueueBufferRef, numPackets: UInt32) {
        let frameCount = Int(numPackets)
        if frameCount > 0 {
            let fPtr = inBuffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
            var sumSq: Double = 0
            for i in 0..<frameCount {
                let v = fPtr[i]
                sumSq += Double(v) * Double(v)
            }

            stateLock.lock()
            let isActiveSession = sessionActive && !allMuted
            let writeToRing = driverAvailable && policy.requiresDriver && isActiveSession
            let mirrorOutput = (!driverAvailable || !policy.requiresDriver) && isActiveSession
            if writeToRing {
                for i in 0..<frameCount {
                    macRing.push(fPtr[i])
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
                let rms = sqrt(sumSq / Double(frameCount))
                let rawDb = rms > 1e-5 ? max(-60.0, 20.0 * log10(rms)) : -120.0
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

        // 若仍处于采麦态，重新把 Buffer 压回队列继续采集
        stateLock.lock()
        let running = captureRunning
        stateLock.unlock()
        if running {
            AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, nil)
        }
    }

    private func startCaptureIfNeeded() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let running = self.captureRunning
            self.stateLock.unlock()
            guard !running else { return }

            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                AppLog.write("AUDIO-PIPE", "缺少麦克风权限，跳过 Mac 物理麦采集")
                return
            }

            var asbd = AudioStreamBasicDescription(
                mSampleRate: Self.outputSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 32,
                mReserved: 0
            )

            var newQueue: AudioQueueRef?
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            let status = AudioQueueNewInput(
                &asbd,
                Self.inputCallback,
                selfPtr,
                nil,
                nil,
                0,
                &newQueue
            )

            guard status == noErr, let queue = newQueue else {
                AppLog.write("AUDIO-PIPE", "创建 AudioQueue 原生物理采麦失败: \(status)")
                return
            }

            // 严选真实物理麦设备：绝不能绑定自身虚拟驱动，即使系统默认设备被临时切到了虚拟声卡
            let physicalUID: String? = {
                if let defaultID = MicRouteCoordinator.defaultInputDeviceID(),
                   let uid = MicRouteCoordinator.deviceUID(for: defaultID),
                   uid != AppStorage.virtualDriverDeviceUID {
                    return uid
                }
                if let savedUID = AppStorage.savedOriginalInputDeviceUID,
                   savedUID != AppStorage.virtualDriverDeviceUID,
                   MicRouteCoordinator.deviceID(withUID: savedUID) != nil {
                    return savedUID
                }
                if let fallbackID = MicRouteCoordinator.firstPhysicalInputDeviceID(),
                   let uid = MicRouteCoordinator.deviceUID(for: fallbackID) {
                    return uid
                }
                return nil
            }()

            if let physicalUID {
                var cfUID: CFString = physicalUID as CFString
                _ = withUnsafePointer(to: &cfUID) { ptr in
                    AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, ptr, UInt32(MemoryLayout<CFString>.size))
                }
            }

            let bufferByteSize = Self.kBufferFrameCount * 4
            var buffers: [AudioQueueBufferRef?] = [nil, nil, nil]
            var allocateSuccess = true
            for i in 0..<3 {
                var buf: AudioQueueBufferRef?
                let allocStatus = AudioQueueAllocateBuffer(queue, bufferByteSize, &buf)
                if allocStatus == noErr, let b = buf {
                    buffers[i] = b
                    AudioQueueEnqueueBuffer(queue, b, 0, nil)
                } else {
                    allocateSuccess = false
                    break
                }
            }

            guard allocateSuccess else {
                AudioQueueDispose(queue, true)
                return
            }

            let startStatus = AudioQueueStart(queue, nil)
            guard startStatus == noErr else {
                AudioQueueDispose(queue, true)
                return
            }

            self.stateLock.lock()
            self.audioQueue = queue
            self.audioBuffers = buffers
            self.captureRunning = true
            self.stateLock.unlock()
            AppLog.write("AUDIO-PIPE", "已启动 AudioQueue 原生轻量硬件采麦（11KB 极小缓冲，零视频媒体库依赖）")
        }
    }

    private func scheduleIdleCaptureStop() {
        idleStopWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.stopCaptureImmediately()
        }
        idleStopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func stopCaptureImmediately() {
        idleStopWorkItem?.cancel()
        idleStopWorkItem = nil
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let queue = self.audioQueue
            self.audioQueue = nil
            self.audioBuffers = [nil, nil, nil]
            self.captureRunning = false
            self.macRing.reset()
            self.macDelayPrimed = false
            self.smoothedMacDb = -120
            self.stateLock.unlock()

            if let queue {
                AudioQueueStop(queue, true)
                AudioQueueDispose(queue, true)
                AppLog.write("AUDIO-PIPE", "物理麦硬件采麦已释放（系统麦克风橙灯瞬灭）")
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

        // 双麦合并时维持 120ms 初始相位对齐延迟线：
        // 初始积攒满 120ms 后标记为 primed，此后只要缓冲未彻底掏空即可平滑连续出队，杜绝周期性断音
        if decision.applyDualMixDelay {
            if !macDelayPrimed && macRing.count >= Self.dualMixDelayFrames {
                macDelayPrimed = true
            } else if macDelayPrimed && macRing.count == 0 {
                macDelayPrimed = false
            }
        } else {
            macDelayPrimed = true
        }
        let allowMacPop = macDelayPrimed

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
