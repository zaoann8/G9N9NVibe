import CoreAudio
import Foundation

/// 系统默认输入设备「永不常驻接管」协调器：
/// 1. 平时待机、仅电脑麦、双麦关闭或退出时，系统默认输入 100% 保持为用户原本的物理麦克风，完全不受接管；
/// 2. 仅当使用微信输入法/系统听写且“正在用遥控器麦收音”的会话瞬间，按需短暂切到虚拟声卡，结束说话立即归还；
/// 3. 若发生强杀/断电导致默认麦残留为虚拟声卡，下次启动立即执行崩溃自愈还原。
enum MicRouteCoordinator {
    /// 启动时执行崩溃自愈：只要系统默认麦残留为本应用虚拟声卡，立即无损还原为物理麦
    static func recoverIfNeeded(driverAvailable: Bool, policy: MicRoutingPolicy, method: VoiceInputMethod) {
        _ = (driverAvailable, policy, method)
        restoreOriginalInputDevice(force: false)
    }

    /// 平时配置变更（切换策略/输入法/双关静音）时：始终确保系统默认输入保持在用户原物理麦，绝不常驻霸占！
    static func apply(driverAvailable: Bool, policy: MicRoutingPolicy, method: VoiceInputMethod) {
        _ = (driverAvailable, policy, method)
        restoreOriginalInputDevice(force: false)
    }

    /// 仅在真正需要经虚拟声卡向跟随系统默认麦的输入法送音时，临时切入虚拟声卡（会话结束立刻归还）
    static func beginTransientVirtualRoute(driverAvailable: Bool, policy: MicRoutingPolicy, method: VoiceInputMethod, source: SessionTriggerSource) {
        guard driverAvailable, policy.requiresDriver, method.followsSystemDefaultInput else { return }
        let usesRemoteAudio = (policy == .remoteOnly || policy == .dualMix || (policy == .smartByTriggerSource && source == .remote))
        guard usesRemoteAudio else { return }
        routeToVirtualMic()
    }

    /// 会话结束立即归还系统默认物理麦
    static func endTransientVirtualRoute() {
        restoreOriginalInputDevice(force: false)
    }

    /// 退出或卸载驱动前无损还原
    static func restoreOriginalInputDevice(force: Bool = false) {
        guard let currentID = defaultInputDeviceID() else { return }
        let currentIsVirtual = (deviceUID(for: currentID) == AppStorage.virtualDriverDeviceUID) ||
            (deviceName(for: currentID) == AppStorage.virtualDriverDeviceName)

        // 尊重用户中途手动选择的新硬件麦
        if !force && !currentIsVirtual {
            return
        }

        if let savedUID = AppStorage.savedOriginalInputDeviceUID,
           let targetID = deviceID(withUID: savedUID),
           targetID != currentID {
            let status = setDefaultInputDevice(targetID)
            AppLog.write("MIC-ROUTE", "已还原系统默认麦 -> \(deviceName(for: targetID) ?? savedUID) status=\(status)")
            AppStorage.savedOriginalInputDeviceUID = nil
            return
        }

        // 若原保存设备已拔出，自动回落至内建物理麦克风
        if let fallbackID = firstPhysicalInputDeviceID() {
            let status = setDefaultInputDevice(fallbackID)
            AppLog.write("MIC-ROUTE", "原设备不可用，回落至物理麦 -> \(deviceName(for: fallbackID) ?? "Built-in") status=\(status)")
            AppStorage.savedOriginalInputDeviceUID = nil
        }
    }

    private static func routeToVirtualMic() {
        guard let virtualID = virtualMicDeviceID() else {
            AppLog.write("MIC-ROUTE", "虚拟声卡尚未就绪，跳过系统路由切换")
            return
        }
        guard let currentID = defaultInputDeviceID() else { return }
        if currentID == virtualID { return }

        if let currentUID = deviceUID(for: currentID), currentUID != AppStorage.virtualDriverDeviceUID {
            AppStorage.savedOriginalInputDeviceUID = currentUID
        }
        let status = setDefaultInputDevice(virtualID)
        AppLog.write("MIC-ROUTE", "已将系统默认输入切换为 \(AppStorage.virtualDriverDeviceName) status=\(status)")
    }

    // MARK: - CoreAudio 底层查询封装

    static func virtualMicDeviceID() -> AudioDeviceID? {
        if let byUID = deviceID(withUID: AppStorage.virtualDriverDeviceUID) {
            return byUID
        }
        return allDeviceIDs().first { deviceName(for: $0) == AppStorage.virtualDriverDeviceName }
    }

    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    @discardableResult
    static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var target = deviceID
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &target
        )
    }

    static func deviceID(withUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { deviceUID(for: $0) == uid }
    }

    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(for deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioObjectPropertyName)
    }

    static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    static func firstPhysicalInputDeviceID() -> AudioDeviceID? {
        let candidates = allDeviceIDs().filter { id in
            guard hasInputChannels(id) else { return false }
            let uid = deviceUID(for: id) ?? ""
            let name = deviceName(for: id) ?? ""
            return uid != AppStorage.virtualDriverDeviceUID && name != AppStorage.virtualDriverDeviceName
        }
        // 优先选择内建麦克风
        if let builtIn = candidates.first(where: { transportType(of: $0) == kAudioDeviceTransportTypeBuiltIn }) {
            return builtIn
        }
        return candidates.first
    }

    static func transportType(of deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return value
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfStr) == noErr,
              let value = cfStr?.takeRetainedValue() else {
            return nil
        }
        return value as String
    }
}
