import AppKit
import CoreAudio
import Foundation

/// 第三方输入法真实 CoreAudio 录音状态探测器（事件驱动，待机零轮询）
/// 1. macOS 14.2+：通过 kAudioProcessPropertyIsRunningInput 精确感知输入法是否在录音，
///    并通过 kAudioProcessPropertyDevices 检测豆包是否选错了麦克风（AudioRouteDoctor 冲突预警）；
/// 2. macOS 12 ~ 14.1：自动降级为兼容模式，避免录音 1 秒超时断开。
final class AudioStateMonitor {
    enum State: String {
        case unavailable
        case inactive
        case active
    }

    struct Snapshot: Equatable {
        let state: State
        let pid: pid_t?
        let inputDeviceNames: [String]
        let captureObservable: Bool

        var isRecording: Bool { state == .active }

        var isUsingVirtualMic: Bool {
            inputDeviceNames.contains(AppStorage.virtualDriverDeviceName)
        }
    }

    let canObserveRecording: Bool
    var onSnapshotChanged: ((Snapshot) -> Void)?

    private var started = false
    private var processObjectID = AudioObjectID(kAudioObjectUnknown)
    private var processPID: pid_t?
    private var boundBundleID: String?
    private var lastSnapshot: Snapshot?
    private var workspaceObservers: [NSObjectProtocol] = []

    private static let processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let runningInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningInput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private static let processDevicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyDevices,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    private lazy var processListListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { self?.refreshBindingAndPublish(force: false) }
    }

    private lazy var inputStateListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { self?.publishCurrentSnapshot(force: false) }
    }

    init() {
        canObserveRecording = Self.probeProcessInputSupport()
        AppLog.write("AUDIO-STATE", "录音探测模式: \(canObserveRecording ? "精确探测 (macOS 14.2+)" : "兼容模式")")
    }

    private static func probeProcessInputSupport() -> Bool {
        var addr = processListAddress
        guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &addr) else {
            return false
        }
        let procs = fetchProcessObjectIDs()
        guard let first = procs.first else {
            return ProcessInfo.processInfo.isOperatingSystemAtLeast(
                OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)
            )
        }
        var runAddr = runningInputAddress
        return AudioObjectHasProperty(first, &runAddr)
    }

    func start() {
        guard !started else { return }
        started = true
        if !canObserveRecording {
            let center = NSWorkspace.shared.notificationCenter
            workspaceObservers = [
                NSWorkspace.didLaunchApplicationNotification,
                NSWorkspace.didTerminateApplicationNotification,
            ].map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.refreshBindingAndPublish(force: false)
                }
            }
            refreshBindingAndPublish(force: true)
            return
        }

        var addr = Self.processListAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            .main,
            processListListener
        )
        refreshBindingAndPublish(force: true)
    }

    func stop() {
        guard started else { return }
        started = false
        unbindProcessObject()
        lastSnapshot = nil
        if !canObserveRecording {
            workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
            workspaceObservers.removeAll()
            return
        }
        var addr = Self.processListAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            .main,
            processListListener
        )
    }

    func targetDidChange() {
        unbindProcessObject()
        boundBundleID = nil
        refreshBindingAndPublish(force: true)
    }

    /// coreaudiod 重启后重建全部监听句柄
    func rebuildAfterAudioDaemonRestart() {
        stop()
        start()
    }

    func snapshotNow() -> Snapshot {
        refreshBindingIfNeeded()
        return readCurrentSnapshot()
    }

    private func refreshBindingAndPublish(force: Bool) {
        refreshBindingIfNeeded()
        publishCurrentSnapshot(force: force)
    }

    private func refreshBindingIfNeeded() {
        let targetBundle = VoiceInputMethod.current.bundleIdentifier
        if boundBundleID != targetBundle {
            unbindProcessObject()
            boundBundleID = targetBundle
        }
        guard let targetBundle else {
            processPID = nil
            return
        }

        let runningApp = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == targetBundle
        }
        processPID = runningApp?.processIdentifier

        guard canObserveRecording, let pid = processPID else {
            unbindProcessObject()
            return
        }
        if processObjectID != kAudioObjectUnknown, Self.processPID(for: processObjectID) == pid {
            return
        }
        unbindProcessObject()

        if let found = Self.fetchProcessObjectIDs().first(where: { Self.processPID(for: $0) == pid }) {
            processObjectID = found
            var runAddr = Self.runningInputAddress
            var devAddr = Self.processDevicesAddress
            AudioObjectAddPropertyListenerBlock(found, &runAddr, .main, inputStateListener)
            AudioObjectAddPropertyListenerBlock(found, &devAddr, .main, inputStateListener)
        }
    }

    private func unbindProcessObject() {
        guard processObjectID != kAudioObjectUnknown else { return }
        var runAddr = Self.runningInputAddress
        var devAddr = Self.processDevicesAddress
        AudioObjectRemovePropertyListenerBlock(processObjectID, &runAddr, .main, inputStateListener)
        AudioObjectRemovePropertyListenerBlock(processObjectID, &devAddr, .main, inputStateListener)
        processObjectID = AudioObjectID(kAudioObjectUnknown)
    }

    private func publishCurrentSnapshot(force: Bool) {
        let snap = readCurrentSnapshot()
        if force || snap != lastSnapshot {
            lastSnapshot = snap
            onSnapshotChanged?(snap)
        }
    }

    private func readCurrentSnapshot() -> Snapshot {
        // 通用模式或低版本系统：走兼容模式（只依据快捷键手势）
        guard canObserveRecording, VoiceInputMethod.current.bundleIdentifier != nil else {
            return Snapshot(state: .unavailable, pid: processPID, inputDeviceNames: [], captureObservable: false)
        }
        guard processObjectID != kAudioObjectUnknown else {
            return Snapshot(state: .unavailable, pid: processPID, inputDeviceNames: [], captureObservable: true)
        }

        var runAddr = Self.runningInputAddress
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processObjectID, &runAddr, 0, nil, &size, &isRunning)
        let state: State = (status == noErr) ? (isRunning != 0 ? .active : .inactive) : .unavailable
        let names = readProcessInputDeviceNames(processObjectID)
        return Snapshot(state: state, pid: processPID, inputDeviceNames: names, captureObservable: true)
    }

    private func readProcessInputDeviceNames(_ objID: AudioObjectID) -> [String] {
        var addr = Self.processDevicesAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objID, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(objID, &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { MicRouteCoordinator.deviceName(for: $0) }
    }

    private static func fetchProcessObjectIDs() -> [AudioObjectID] {
        var addr = processListAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func processPID(for objID: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objID, &addr, 0, nil, &size, &pid) == noErr else {
            return nil
        }
        return pid
    }
}
