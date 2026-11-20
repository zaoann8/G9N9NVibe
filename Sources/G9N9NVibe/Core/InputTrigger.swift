import CoreGraphics
import Foundation

/// 语音输入法的快捷键按法模式
enum InputTriggerMode: String, CaseIterable, Codable, Identifiable {
    /// 长按说话：按键持续按住，松手停止识别
    case hold
    /// 短按开关：按一下开始，再按一下停止
    case toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hold: return "长按说话"
        case .toggle: return "短按开关"
        }
    }
}

/// 左右单修饰键定义（附带 IOKit 设备级左右侧修饰位）
enum ModifierTriggerKey: String, CaseIterable, Codable, Hashable, Identifiable {
    case rightOption
    case leftOption
    case rightCommand
    case leftCommand
    case rightControl
    case leftControl
    case rightShift
    case leftShift
    case function

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: return "右 Option (⌥)"
        case .leftOption: return "左 Option (⌥)"
        case .rightCommand: return "右 Command (⌘)"
        case .leftCommand: return "左 Command (⌘)"
        case .rightControl: return "右 Control (⌃)"
        case .leftControl: return "左 Control (⌃)"
        case .rightShift: return "右 Shift (⇧)"
        case .leftShift: return "左 Shift (⇧)"
        case .function: return "Fn 地球键"
        }
    }

    var shortTitle: String {
        switch self {
        case .rightOption: return "右 ⌥"
        case .leftOption: return "左 ⌥"
        case .rightCommand: return "右 ⌘"
        case .leftCommand: return "左 ⌘"
        case .rightControl: return "右 ⌃"
        case .leftControl: return "左 ⌃"
        case .rightShift: return "右 ⇧"
        case .leftShift: return "左 ⇧"
        case .function: return "Fn"
        }
    }

    func title(lang: AppLanguage) -> String {
        guard lang == .en else { return title }
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .leftOption: return "Left Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .leftCommand: return "Left Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .leftControl: return "Left Control (⌃)"
        case .rightShift: return "Right Shift (⇧)"
        case .leftShift: return "Left Shift (⇧)"
        case .function: return "Fn Globe"
        }
    }

    func shortTitle(lang: AppLanguage) -> String {
        guard lang == .en else { return shortTitle }
        switch self {
        case .rightOption: return "R ⌥"
        case .leftOption: return "L ⌥"
        case .rightCommand: return "R ⌘"
        case .leftCommand: return "L ⌘"
        case .rightControl: return "R ⌃"
        case .leftControl: return "L ⌃"
        case .rightShift: return "R ⇧"
        case .leftShift: return "L ⇧"
        case .function: return "Fn"
        }
    }

    var keyCode: CGKeyCode {
        switch self {
        case .leftOption: return 0x3A
        case .rightOption: return 0x3D
        case .leftCommand: return 0x37
        case .rightCommand: return 0x36
        case .leftControl: return 0x3B
        case .rightControl: return 0x3E
        case .leftShift: return 0x38
        case .rightShift: return 0x3C
        case .function: return 0x3F
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .leftOption, .rightOption: return .maskAlternate
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftControl, .rightControl: return .maskControl
        case .leftShift, .rightShift: return .maskShift
        case .function: return .maskSecondaryFn
        }
    }

    /// IOLLEvent.h 中定义的设备级左右侧修饰键位，确保豆包/微信能准确区分左右键
    var sideFlag: CGEventFlags {
        switch self {
        case .leftControl: return CGEventFlags(rawValue: 0x0000_0001)
        case .leftShift: return CGEventFlags(rawValue: 0x0000_0002)
        case .rightShift: return CGEventFlags(rawValue: 0x0000_0004)
        case .leftCommand: return CGEventFlags(rawValue: 0x0000_0008)
        case .rightCommand: return CGEventFlags(rawValue: 0x0000_0010)
        case .leftOption: return CGEventFlags(rawValue: 0x0000_0020)
        case .rightOption: return CGEventFlags(rawValue: 0x0000_0040)
        case .rightControl: return CGEventFlags(rawValue: 0x0000_2000)
        case .function: return []
        }
    }

    static func from(keyCode: UInt16) -> ModifierTriggerKey? {
        allCases.first { UInt16($0.keyCode) == keyCode }
    }
}

/// 统一的语音触发键配置：既支持左右单修饰键，也支持任意自定义单键/组合键（如 ⌥ Space、⌘ ⇧ V、F5）
struct VoiceTriggerShortcut: Codable, Equatable, Hashable {
    enum Kind: String, Codable {
        case modifier
        case keyCombo
    }

    let kind: Kind
    let modifier: ModifierTriggerKey?
    let keyCode: UInt16
    let flagsRawValue: UInt64
    let label: String
    let shortLabel: String
    let isCustomRecorded: Bool

    static let rightOption = VoiceTriggerShortcut.preset(.rightOption)
    static let leftOption = VoiceTriggerShortcut.preset(.leftOption)
    static let rightCommand = VoiceTriggerShortcut.preset(.rightCommand)
    static let leftCommand = VoiceTriggerShortcut.preset(.leftCommand)
    static let rightControl = VoiceTriggerShortcut.preset(.rightControl)
    static let functionKey = VoiceTriggerShortcut.preset(.function)
    static let optionSpace = VoiceTriggerShortcut(
        kind: .keyCombo,
        modifier: nil,
        keyCode: 0x31,
        flagsRawValue: CGEventFlags.maskAlternate.rawValue,
        label: "⌥ Space",
        shortLabel: "⌥ Space",
        isCustomRecorded: false
    )
    static let commandShiftV = VoiceTriggerShortcut(
        kind: .keyCombo,
        modifier: nil,
        keyCode: 0x09,
        flagsRawValue: CGEventFlags.maskCommand.union(.maskShift).rawValue,
        label: "⌘ ⇧ V",
        shortLabel: "⌘ ⇧ V",
        isCustomRecorded: false
    )

    static let presets: [VoiceTriggerShortcut] = [
        .rightOption, .leftOption, .rightCommand, .leftCommand,
        .rightControl, .functionKey, .optionSpace, .commandShiftV
    ]

    static func preset(_ mod: ModifierTriggerKey) -> VoiceTriggerShortcut {
        VoiceTriggerShortcut(
            kind: .modifier,
            modifier: mod,
            keyCode: UInt16(mod.keyCode),
            flagsRawValue: mod.flag.union(mod.sideFlag).rawValue,
            label: mod.title,
            shortLabel: mod.shortTitle,
            isCustomRecorded: false
        )
    }

    static func customModifier(_ mod: ModifierTriggerKey) -> VoiceTriggerShortcut {
        VoiceTriggerShortcut(
            kind: .modifier,
            modifier: mod,
            keyCode: UInt16(mod.keyCode),
            flagsRawValue: mod.flag.union(mod.sideFlag).rawValue,
            label: mod.title,
            shortLabel: mod.shortTitle,
            isCustomRecorded: true
        )
    }

    static func customCombo(keyCode: UInt16, flags: CGEventFlags, label: String) -> VoiceTriggerShortcut {
        let relevant = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn])
        return VoiceTriggerShortcut(
            kind: .keyCombo,
            modifier: nil,
            keyCode: keyCode,
            flagsRawValue: relevant.rawValue,
            label: label,
            shortLabel: label,
            isCustomRecorded: true
        )
    }

    var eventFlags: CGEventFlags {
        CGEventFlags(rawValue: flagsRawValue)
    }

    func displayLabel(lang: AppLanguage) -> String {
        if let mod = modifier {
            return mod.title(lang: lang)
        }
        return label
    }

    func displayShortLabel(lang: AppLanguage) -> String {
        if let mod = modifier {
            return mod.shortTitle(lang: lang)
        }
        return shortLabel
    }
}

/// 全局合成按键发送器：带防循环标记与防卡键保护
enum InputTrigger {
    /// 标记本应用合成的 CGEvent，防止被 KeyboardTapMonitor 误识别为物理键盘操作
    static let syntheticMarker: Int64 = 0x47_39_56_42 // "G9VB"

    private static var heldShortcut: VoiceTriggerShortcut?

    /// 启动语音识别：长按模式持续按下，短按模式发送一次 60ms 点击（前置 25ms 广播生效窗口确保输入法秒级识别到虚拟声卡）
    static func beginRecognition() {
        let shortcut = AppStorage.voiceTriggerShortcut
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            switch AppStorage.inputTriggerMode {
            case .toggle:
                tap(shortcut)
            case .hold:
                guard heldShortcut == nil else { return }
                heldShortcut = shortcut
                post(shortcut: shortcut, isDown: true)
            }
        }
    }

    /// 结束语音识别
    static func endRecognition() {
        switch AppStorage.inputTriggerMode {
        case .toggle:
            tap(AppStorage.voiceTriggerShortcut)
        case .hold:
            releaseHeldTrigger()
        }
    }

    /// 兜底释放任何按住的语音快捷键（切换模式、蓝牙断连、应用退出时必须调用，杜绝卡键）
    static func releaseHeldTrigger() {
        guard let shortcut = heldShortcut else { return }
        heldShortcut = nil
        post(shortcut: shortcut, isDown: false)
    }

    static func tap(_ shortcut: VoiceTriggerShortcut, completion: (() -> Void)? = nil) {
        post(shortcut: shortcut, isDown: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            post(shortcut: shortcut, isDown: false)
            completion?()
        }
    }

    static func post(shortcut: VoiceTriggerShortcut, isDown: Bool) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        switch shortcut.kind {
        case .modifier:
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(shortcut.keyCode),
                keyDown: isDown
            ) else { return }
            event.type = .flagsChanged
            event.flags = isDown ? shortcut.eventFlags : []
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            event.post(tap: .cghidEventTap)
            AppLog.write("TRIGGER", "合成修饰键 \(shortcut.label) \(isDown ? "DOWN" : "UP")")

        case .keyCombo:
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(shortcut.keyCode),
                keyDown: isDown
            ) else { return }
            event.flags = shortcut.eventFlags
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            event.post(tap: .cghidEventTap)
            AppLog.write("TRIGGER", "合成组合键 \(shortcut.label) \(isDown ? "DOWN" : "UP")")
        }
    }
}
