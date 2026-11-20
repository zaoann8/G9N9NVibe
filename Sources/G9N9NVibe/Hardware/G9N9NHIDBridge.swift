import Foundation
import IOKit.hid

private func g9n9nDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<G9N9NHIDBridge>.fromOpaque(context).takeUnretainedValue()
        .deviceDidMatch(result: result, device: device)
}

private func g9n9nDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<G9N9NHIDBridge>.fromOpaque(context).takeUnretainedValue()
        .deviceDidRemove(device)
}

private func g9n9nInputReport(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context, result == kIOReturnSuccess, reportLength > 0 else { return }
    Unmanaged<G9N9NHIDBridge>.fromOpaque(context).takeUnretainedValue()
        .handleReport(reportID: reportID, data: Data(bytes: report, count: reportLength))
}

/// Google Chromecast (G9N9N) HID 按键拦截与分发桥接器
/// VID = 0x18D1, PID = 0x9450；启用映射时以 Seize 模式独占设备，避免系统媒体行为误触发
final class G9N9NHIDBridge {
    static let vendorID = 0x18D1
    static let productID = 0x9450

    var onConnectionChanged: ((Bool) -> Void)?
    /// 供 UI 在按键映射页实时高亮物理按下的键帽
    var onButtonPressedFeedback: ((String, Bool) -> Void)?
    /// 当某个按键被映射为「一键切换收音麦克风」时由外层路由控制器处理
    var onSwapMicRequested: (() -> Void)?

    private var manager: IOHIDManager?
    private var activeDevice: IOHIDDevice?
    private var remappingEnabled = AppStorage.remoteMappingEnabled
    private var lastButtonID: String?
    /// 短按 + 长按双功能状态（仅对配置了长按动作的功能键生效，其余按键保持 0ms 瞬发）
    private var pendingLongPressButton: G9N9NButtonDefinition?
    private var longPressWorkItem: DispatchWorkItem?
    private var longPressDidFire = false
    private static let longPressThreshold: TimeInterval = 0.38

    var isConnected: Bool { activeDevice != nil }

    func start() {
        stop()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: Self.vendorID,
            kIOHIDProductIDKey: Self.productID,
        ] as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, g9n9nDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, g9n9nDeviceRemoved, context)
        IOHIDManagerRegisterInputReportCallback(manager, g9n9nInputReport, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let openOptions = remappingEnabled
            ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            : IOOptionBits(kIOHIDOptionsTypeNone)
        var result = IOHIDManagerOpen(manager, openOptions)
        if result == kIOReturnNotPrivileged, remappingEnabled {
            AppLog.write("G9N9N-HID", "Seize 权限不足，降级为共享监听模式")
            result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        guard result == kIOReturnSuccess else {
            AppLog.write("G9N9N-HID", "打开 HID Manager 失败: 0x\(String(format: "%08X", UInt32(bitPattern: result)))")
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return
        }
        self.manager = manager
        AppLog.write("G9N9N-HID", "等待 G9N9N HID 设备接入 (remap=\(remappingEnabled))")
    }

    func stop() {
        cancelPendingLongPress()
        activeDevice = nil
        lastButtonID = nil
        onConnectionChanged?(false)
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    func setRemappingEnabled(_ enabled: Bool) {
        guard remappingEnabled != enabled else { return }
        remappingEnabled = enabled
        start()
    }

    /// 系统休眠唤醒（Wake）自愈：若当前无活动设备，重新拉起 HID Manager 扫描重连
    func wakeRecover() {
        guard remappingEnabled else { return }
        if activeDevice == nil {
            AppLog.write("G9N9N-HID", "系统唤醒且无活跃设备，重新初始化 HID 设备监听")
            start()
        }
    }

    fileprivate func deviceDidMatch(result: IOReturn, device: IOHIDDevice) {
        guard result == kIOReturnSuccess, activeDevice == nil else { return }
        activeDevice = device
        onConnectionChanged?(true)
        AppLog.write("G9N9N-HID", "G9N9N 已连接 VID=0x18D1 PID=0x9450")
    }

    fileprivate func deviceDidRemove(_ device: IOHIDDevice) {
        guard let activeDevice, CFEqual(activeDevice, device) else { return }
        cancelPendingLongPress()
        self.activeDevice = nil
        self.lastButtonID = nil
        onConnectionChanged?(false)
        AppLog.write("G9N9N-HID", "G9N9N 已断开")
    }

    fileprivate func handleReport(reportID: UInt32, data: Data) {
        guard reportID == 0x01 else { return }
        let payload = data.first == UInt8(truncatingIfNeeded: reportID) ? Data(data.dropFirst()) : data
        guard let usage = payload.first else { return }

        if usage == 0 {
            guard let buttonID = lastButtonID else { return }
            lastButtonID = nil
            apply(buttonID: buttonID, isDown: false)
            return
        }

        let buttonID = String(format: "%02X", usage)
        guard lastButtonID != buttonID else { return }
        if let previous = lastButtonID {
            apply(buttonID: previous, isDown: false)
        }
        lastButtonID = buttonID
        apply(buttonID: buttonID, isDown: true)
    }

    private func cancelPendingLongPress() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        pendingLongPressButton = nil
        longPressDidFire = false
    }

    private func apply(buttonID: String, isDown: Bool) {
        onButtonPressedFeedback?(buttonID, isDown)
        guard remappingEnabled,
              let button = RemoteProfiles.g9n9nButtons.first(where: { $0.id == buttonID }) else {
            return
        }
        let store = RemoteMappingStore.shared

        // 若该按键配置了「长按第二功能」，走 0.38s 短按/长按双功能分发
        if store.hasActiveLongPress(for: button) {
            if isDown {
                cancelPendingLongPress()
                pendingLongPressButton = button
                longPressDidFire = false
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.remappingEnabled, self.pendingLongPressButton?.id == button.id else { return }
                    self.longPressDidFire = true
                    self.longPressWorkItem = nil
                    let lpTarget = store.longPressTarget(for: button)
                    guard lpTarget != .disabled else { return }
                    if lpTarget == .swapMicrophone {
                        self.onSwapMicRequested?()
                    } else {
                        store.fireTap(button: button, isLongPress: true)
                    }
                    self.onButtonPressedFeedback?(button.id, true)
                }
                longPressWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPressThreshold, execute: work)
            } else {
                let wasPending = (pendingLongPressButton?.id == button.id)
                let firedLong = longPressDidFire
                cancelPendingLongPress()
                // 未满长按阈值松手 → 立即执行短按动作
                if wasPending && !firedLong {
                    let shortTarget = store.target(for: button)
                    if shortTarget == .swapMicrophone {
                        onSwapMicRequested?()
                    } else {
                        store.fireTap(button: button, isLongPress: false)
                    }
                }
            }
            return
        }

        // 未配置长按第二功能的按键：保持 0ms 按下即触发（方向键/音量键无缝连发）
        let target = store.target(for: button)
        if target == .swapMicrophone {
            if isDown {
                onSwapMicRequested?()
            }
            return
        }
        store.post(button: button, isDown: isDown)
    }
}
