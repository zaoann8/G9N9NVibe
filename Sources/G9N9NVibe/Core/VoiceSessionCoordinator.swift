import Foundation

/// 录音状态提供协议（方便自测进行 Mock 注入）
protocol AudioStateProviding: AnyObject {
    var onSnapshotChanged: ((AudioStateMonitor.Snapshot) -> Void)? { get set }
    var canObserveRecording: Bool { get }
    func start()
    func stop()
    func snapshotNow() -> AudioStateMonitor.Snapshot
}

extension AudioStateMonitor: AudioStateProviding {}

/// G9N9N-Vibe 核心语音会话状态机：
/// - 统一协调「遥控器物理语音键（短按切换 / 长按对讲）」与「Mac 实体键盘触发键」
/// - 严格维护会话所有权（owner），将精确触发源通知给 AudioPipe，支撑「智能随动」零冲突选麦
/// - 兼容 macOS 14.2+ 精确录音状态探测与 macOS 12~14.1 兼容模式
final class VoiceSessionCoordinator {
    enum Phase: String {
        case closed
        case opening
        case open
        case closing
    }

    enum Owner: String {
        case none
        case remote
        case keyboard
    }

    struct DebugSnapshot: Equatable {
        let phase: Phase
        let owner: Owner
        let isRemoteStreaming: Bool
    }

    private static let holdThreshold: TimeInterval = 0.55
    private static let openTimeout: TimeInterval = 1.1
    private static let closeTimeout: TimeInterval = 1.0
    private static let maxAutoSafetyTimeout: TimeInterval = 60.0 // 防后台永久亮橙灯最大单次保护时长

    private let audioState: any AudioStateProviding
    private let setAudioSessionActive: (Bool, SessionTriggerSource) -> Void
    private let shouldConsumeRemoteAudio: () -> Bool
    private let sendTrigger: (Bool) -> Void
    private let releaseTrigger: () -> Void
    private let triggerMode: () -> InputTriggerMode
    private let now: () -> Date

    private var phase: Phase = .closed
    private var owner: Owner = .none
    private var isRemoteStreaming = false
    private var gestureBeganAt: Date?
    private var recognitionWasOpenAtPress = false
    private var openTimeoutWork: DispatchWorkItem?
    private var closeTimeoutWork: DispatchWorkItem?
    private var safetyTimeoutWork: DispatchWorkItem?

    var onRequestOpenRemoteMic: ((_ bypassDebounce: Bool) -> RemoteMicrophoneOpenResult)?
    var onRequestCloseRemoteMic: (() -> Void)?
    var onStatusChanged: ((String, SessionTriggerSource, Bool) -> Void)?

    init(
        audioState: any AudioStateProviding,
        setAudioSessionActive: @escaping (Bool, SessionTriggerSource) -> Void = { active, src in
            AudioPipe.shared.setSessionActive(active, triggerSource: src)
        },
        shouldConsumeRemoteAudio: @escaping () -> Bool = { AudioPipe.shared.shouldAcceptRemoteAudio() },
        sendTrigger: @escaping (Bool) -> Void = { begin in
            begin ? InputTrigger.beginRecognition() : InputTrigger.endRecognition()
        },
        releaseTrigger: @escaping () -> Void = { InputTrigger.releaseHeldTrigger() },
        triggerMode: @escaping () -> InputTriggerMode = { AppStorage.inputTriggerMode },
        now: @escaping () -> Date = Date.init
    ) {
        self.audioState = audioState
        self.setAudioSessionActive = setAudioSessionActive
        self.shouldConsumeRemoteAudio = shouldConsumeRemoteAudio
        self.sendTrigger = sendTrigger
        self.releaseTrigger = releaseTrigger
        self.triggerMode = triggerMode
        self.now = now
    }

    var debugSnapshot: DebugSnapshot {
        DebugSnapshot(phase: phase, owner: owner, isRemoteStreaming: isRemoteStreaming)
    }

    private var isCompatibilityMode: Bool {
        !audioState.canObserveRecording || VoiceInputMethod.current == .generic
    }

    func start() {
        audioState.onSnapshotChanged = { [weak self] snap in
            self?.handleAudioSnapshot(snap)
        }
        audioState.start()
    }

    func stopAndReleaseAll() {
        cancelTimers()
        releaseTrigger()
        onRequestCloseRemoteMic?()
        setAudioSessionActive(false, .none)
        phase = .closed
        owner = .none
        isRemoteStreaming = false
        gestureBeganAt = nil
        onStatusChanged?("等待录音", .none, false)
    }

    // MARK: - 遥控器 BLE ATVV 事件入口

    /// 遥控器收到 AUDIO_START（reason == 0x03 代表物理按下语音键）
    func remoteAudioStarted(reason: UInt8) {
        isRemoteStreaming = true
        let snap = audioState.snapshotNow()

        if phase == .closing {
            onRequestCloseRemoteMic?()
            return
        }

        if reason == 0x03 {
            let alreadyOpen = (phase == .open || phase == .opening || snap.isRecording)
            gestureBeganAt = now()
            recognitionWasOpenAtPress = alreadyOpen

            if alreadyOpen {
                // 已在录音时再次按下：等待松手判断是否为短按关闭
                return
            }

            beginSession(owner: .remote)
            sendTrigger(true)
            return
        }

        // 非物理按下（如主机请求续麦）：仅当当前会话所有者确为 .remote 时才维持遥控器音频，防止键盘会话被遥控器误抢占
        if (phase == .open || phase == .opening) && owner == .remote {
            setAudioSessionActive(true, .remote)
        } else {
            onRequestCloseRemoteMic?()
        }
    }

    /// 遥控器收到 AUDIO_STOP（reason == 0x02 代表物理松开语音键；0xFB~0xFE 代表断连/关蓝牙/异常终止）
    func remoteAudioStopped(reason: UInt8) {
        isRemoteStreaming = false

        // 蓝牙断连 / 蓝牙关闭 / 本地强停：若当前由遥控器持有会话，必须立即强收敛并释放按住的语音快捷键（防卡键）
        if reason >= 0xFB {
            gestureBeganAt = nil
            recognitionWasOpenAtPress = false
            if owner == .remote && (phase == .open || phase == .opening) {
                AppLog.write("VOICE-SESSION", "遥控器蓝牙异常断开(0x\(String(format: "%02X", reason)))，立即收敛会话并释放按键")
                closeSession(sendStopTrigger: true)
            }
            return
        }

        guard reason == 0x02, let began = gestureBeganAt else {
            // 非物理松开（如遥控器硬件 15~30 秒单流超时），若仍在录音且由遥控器持有且需要遥控器音频，尝试静默续麦（直通防抖）
            if phase == .open, owner == .remote, shouldConsumeRemoteAudio() {
                _ = onRequestOpenRemoteMic?(true)
            }
            return
        }

        let heldDuration = now().timeIntervalSince(began)
        gestureBeganAt = nil

        if recognitionWasOpenAtPress {
            // 原先已打开录音，短按一次代表关闭
            closeSession(sendStopTrigger: true)
            return
        }

        if heldDuration >= Self.holdThreshold {
            // 长按对讲：松手立即停止识别
            closeSession(sendStopTrigger: true)
        } else {
            // 短按切换：保持录音开启；若当前需要遥控器麦则重新打开遥控器持续收音（强制直通防抖，杜绝短按丢麦）
            if phase == .open || phase == .opening {
                if shouldConsumeRemoteAudio() {
                    _ = onRequestOpenRemoteMic?(true)
                }
                publishCurrentStatus()
            }
        }
    }

    // MARK: - Mac 物理键盘触发键事件入口（驱动「智能随动」选通电脑麦）

    func physicalKeyboardTriggerDown() {
        let snap = audioState.snapshotNow()
        let currentlyOpen = (phase == .open || phase == .opening || snap.isRecording)

        if triggerMode() == .hold {
            if !currentlyOpen {
                beginSession(owner: .keyboard)
            }
        } else {
            if currentlyOpen {
                closeSession(sendStopTrigger: false)
            } else {
                beginSession(owner: .keyboard)
            }
        }
    }

    func physicalKeyboardTriggerUp() {
        guard triggerMode() == .hold, owner == .keyboard else { return }
        closeSession(sendStopTrigger: false)
    }

    // MARK: - 第三方输入法真实 CoreAudio 状态反馈

    func handleAudioSnapshot(_ snapshot: AudioStateMonitor.Snapshot) {
        guard !isCompatibilityMode else { return }

        if snapshot.isRecording {
            if phase == .opening || phase == .closed {
                openTimeoutWork?.cancel()
                openTimeoutWork = nil
                phase = .open
                if owner == .none { owner = .keyboard }
                setAudioSessionActive(true, triggerSourceForCurrentOwner())
                publishCurrentStatus()
            }
        } else {
            if phase == .open || phase == .closing {
                finishClosing()
            }
        }
    }

    // MARK: - 内部状态跃迁

    private func beginSession(owner newOwner: Owner) {
        cancelTimers()
        owner = newOwner
        let src: SessionTriggerSource = (newOwner == .remote) ? .remote : .keyboard
        setAudioSessionActive(true, src)

        if isCompatibilityMode {
            phase = .open
            publishCurrentStatus()
            scheduleSafetyAutoClose()
            return
        }

        phase = .opening
        publishCurrentStatus()

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .opening else { return }
            let snap = self.audioState.snapshotNow()
            if snap.isRecording {
                self.phase = .open
                self.publishCurrentStatus()
                self.scheduleSafetyAutoClose()
            } else {
                AppLog.write("VOICE-SESSION", "开麦确认超时，自动收敛关闭（请检查触发键是否与输入法一致）")
                self.finishClosing()
            }
        }
        openTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.openTimeout, execute: work)
    }

    private func closeSession(sendStopTrigger: Bool) {
        cancelTimers()
        if sendStopTrigger {
            sendTrigger(false)
        }
        releaseTrigger()
        onRequestCloseRemoteMic?()

        if isCompatibilityMode {
            finishClosing()
            return
        }

        phase = .closing
        let work = DispatchWorkItem { [weak self] in
            self?.finishClosing()
        }
        closeTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeTimeout, execute: work)
    }

    private func finishClosing() {
        cancelTimers()
        releaseTrigger()
        if isRemoteStreaming {
            onRequestCloseRemoteMic?()
        }
        phase = .closed
        owner = .none
        setAudioSessionActive(false, .none)
        onStatusChanged?("等待录音", .none, false)
    }

    private func cancelTimers() {
        openTimeoutWork?.cancel()
        openTimeoutWork = nil
        closeTimeoutWork?.cancel()
        closeTimeoutWork = nil
        safetyTimeoutWork?.cancel()
        safetyTimeoutWork = nil
    }

    private func scheduleSafetyAutoClose() {
        safetyTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .open else { return }
            AppLog.write("VOICE-SESSION", "短按开麦已达最大单次安全保护时长(60s)，自动收敛关麦防悬挂")
            self.closeSession(sendStopTrigger: true)
        }
        safetyTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxAutoSafetyTimeout, execute: work)
    }

    private func triggerSourceForCurrentOwner() -> SessionTriggerSource {
        switch owner {
        case .remote: return .remote
        case .keyboard: return .keyboard
        case .none: return .none
        }
    }

    private func publishCurrentStatus() {
        let src = triggerSourceForCurrentOwner()
        let active = (phase == .open || phase == .opening)
        let suffix = isCompatibilityMode ? "（兼容）" : ""
        let text: String
        if !active {
            text = "等待录音"
        } else if src == .remote {
            text = "\(VoiceInputMethod.current.shortName)录音中 · 遥控器触发\(suffix)"
        } else {
            text = "\(VoiceInputMethod.current.shortName)录音中 · 键盘触发\(suffix)"
        }
        onStatusChanged?(text, src, active)
    }
}
