import CoreGraphics
import Foundation

/// 全局物理键盘触发键监听（基于 CGEventTap）：
/// 用于识别用户在 Mac 实体键盘上按下语音触发键，以驱动「智能随动」选通电脑麦与状态机同步
final class KeyboardTapMonitor {
    var onPhysicalTriggerDown: (() -> Void)?
    var onPhysicalTriggerUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var physicalDown = false

    func start() {
        guard eventTap == nil else { return }
        let mask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeyboardTapMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handleEvent(type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: selfPtr
        ) else {
            AppLog.write("KEY-TAP", "无法创建 CGEventTap（需要辅助功能或输入监控权限）")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        AppLog.write("KEY-TAP", "全局物理键盘触发监听已启动")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        physicalDown = false
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // 忽略本应用自己合成的事件，防止死循环
        if event.getIntegerValueField(.eventSourceUserData) == InputTrigger.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        let shortcut = AppStorage.voiceTriggerShortcut
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        switch shortcut.kind {
        case .modifier:
            guard type == .flagsChanged,
                  let mod = shortcut.modifier,
                  keyCode == shortcut.keyCode else {
                return Unmanaged.passUnretained(event)
            }
            let isPressed = event.flags.contains(mod.flag)
            if isPressed, !physicalDown {
                physicalDown = true
                DispatchQueue.main.async { [weak self] in
                    self?.onPhysicalTriggerDown?()
                }
            } else if !isPressed, physicalDown {
                physicalDown = false
                DispatchQueue.main.async { [weak self] in
                    self?.onPhysicalTriggerUp?()
                }
            }

        case .keyCombo:
            guard keyCode == shortcut.keyCode else {
                return Unmanaged.passUnretained(event)
            }
            let standardMask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
            let required = shortcut.eventFlags.intersection(standardMask)
            let actual = event.flags.intersection(standardMask)

            if type == .keyDown, actual == required, !physicalDown {
                physicalDown = true
                DispatchQueue.main.async { [weak self] in
                    self?.onPhysicalTriggerDown?()
                }
            } else if type == .keyUp, physicalDown {
                physicalDown = false
                DispatchQueue.main.async { [weak self] in
                    self?.onPhysicalTriggerUp?()
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
