import AppKit
import CoreGraphics
import Foundation

/// G9N9N 按键定义（共 15 键：14 个可自定义 HID 按键 + 1 个 BLE 语音键）
struct G9N9NButtonDefinition: Identifiable, Hashable {
    let id: String
    let title: String
    let englishTitle: String
    let badge: String
    let isVoiceKey: Bool
    /// 是否开放「长按第二功能」（方向键与音量侧键需保持按下即连发，仅 8 枚功能键支持短按+长按双功能）
    let supportsLongPress: Bool

    init(
        id: String,
        title: String,
        englishTitle: String,
        badge: String,
        isVoiceKey: Bool = false,
        supportsLongPress: Bool = false
    ) {
        self.id = id
        self.title = title
        self.englishTitle = englishTitle
        self.badge = badge
        self.isVoiceKey = isVoiceKey
        self.supportsLongPress = supportsLongPress
    }

    func title(lang: AppLanguage) -> String {
        lang == .en ? englishTitle : title
    }
}

enum RemoteProfiles {
    static let g9n9nButtons: [G9N9NButtonDefinition] = [
        .init(id: "03", title: "方向上", englishTitle: "Up", badge: "↑"),
        .init(id: "04", title: "方向下", englishTitle: "Down", badge: "↓"),
        .init(id: "05", title: "方向左", englishTitle: "Left", badge: "←"),
        .init(id: "06", title: "方向右", englishTitle: "Right", badge: "→"),
        .init(id: "07", title: "确认", englishTitle: "Select / OK", badge: "OK", supportsLongPress: true),
        .init(id: "0B", title: "返回", englishTitle: "Back", badge: "←", supportsLongPress: true),
        .init(id: "0A", title: "Home", englishTitle: "Home", badge: "H", supportsLongPress: true),
        .init(id: "08", title: "静音", englishTitle: "Mute", badge: "M", supportsLongPress: true),
        .init(id: "0E", title: "YouTube", englishTitle: "YouTube", badge: "YT", supportsLongPress: true),
        .init(id: "0F", title: "Netflix", englishTitle: "Netflix", badge: "NF", supportsLongPress: true),
        .init(id: "01", title: "电源", englishTitle: "Power", badge: "⏻", supportsLongPress: true),
        .init(id: "11", title: "信源", englishTitle: "Input", badge: "⇄", supportsLongPress: true),
        .init(id: "0C", title: "音量 ＋", englishTitle: "Volume ＋", badge: "+"),
        .init(id: "0D", title: "音量 －", englishTitle: "Volume −", badge: "−"),
        .init(id: "voice", title: "语音键", englishTitle: "Voice Key", badge: "MIC", isVoiceKey: true),
    ]
}

/// 按键动作分类（用于定制 Popover 的清爽分类筛选）
enum MappingActionCategory: String, CaseIterable, Identifiable {
    case all = "全部"
    case vibe = "编程"
    case keys = "基础键"
    case system = "系统"

    var id: String { rawValue }

    func title(lang: AppLanguage) -> String {
        guard lang == .en else { return rawValue }
        switch self {
        case .all: return "All"
        case .vibe: return "Coding"
        case .keys: return "Keys"
        case .system: return "System"
        }
    }
}

/// 全部 36 项内置映射动作（含 Vibe Coding 专属常用快捷键，仅发送至前台窗口无全局热键冲突）+ 自定义录制
enum RemoteMappingTarget: String, CaseIterable, Identifiable, Codable, Hashable {
    // 编程与 AI 效率
    case returnKey
    case shiftReturn
    case escape
    case appSwitcher
    case aiInlineEdit
    case aiOpenChat
    case aiAccept
    case toggleTerminal
    case swapMicrophone
    case commandA
    case commandC
    case commandV
    case commandZ
    case commandShiftZ
    case areaScreenshot
    case newTab
    case spotlight
    // 基础键盘
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case deleteBackward
    case tab
    case space
    case pageUp
    case pageDown
    case home
    case end
    // 媒体与系统
    case showDesktop
    case volumeUp
    case volumeDown
    case mute
    case playPause
    case lockScreen
    case sleep
    case disabled
    // 自定义录制
    case custom

    var id: String { rawValue }

    var category: MappingActionCategory {
        switch self {
        case .returnKey, .shiftReturn, .escape, .appSwitcher, .aiInlineEdit, .aiOpenChat, .aiAccept,
             .toggleTerminal, .swapMicrophone, .commandA, .commandC, .commandV, .commandZ, .commandShiftZ,
             .areaScreenshot, .newTab, .spotlight:
            return .vibe
        case .arrowUp, .arrowDown, .arrowLeft, .arrowRight, .deleteBackward,
             .tab, .space, .pageUp, .pageDown, .home, .end:
            return .keys
        default:
            return .system
        }
    }

    var title: String {
        switch self {
        case .returnKey: return "回车发送"
        case .shiftReturn: return "换行不发送"
        case .escape: return "取消退出"
        case .appSwitcher: return "切换应用"
        case .aiInlineEdit: return "AI 行内编辑"
        case .aiOpenChat: return "AI 对话面板"
        case .aiAccept: return "接受代码"
        case .toggleTerminal: return "切换终端"
        case .swapMicrophone: return "切换麦克风"
        case .commandA: return "全选"
        case .commandC: return "复制"
        case .commandV: return "粘贴"
        case .commandZ: return "撤销"
        case .commandShiftZ: return "重做"
        case .areaScreenshot: return "区域截图"
        case .newTab: return "新建标签"
        case .spotlight: return "Spotlight"
        case .arrowUp: return "方向上"
        case .arrowDown: return "方向下"
        case .arrowLeft: return "方向左"
        case .arrowRight: return "方向右"
        case .deleteBackward: return "退格删除"
        case .tab: return "Tab"
        case .space: return "空格"
        case .pageUp: return "向上翻页"
        case .pageDown: return "向下翻页"
        case .home: return "Home"
        case .end: return "End"
        case .showDesktop: return "显示桌面"
        case .volumeUp: return "系统音量＋"
        case .volumeDown: return "系统音量－"
        case .mute: return "系统静音"
        case .playPause: return "播放暂停"
        case .lockScreen: return "锁屏"
        case .sleep: return "睡眠"
        case .disabled: return "禁用防误触"
        case .custom: return "自定义"
        }
    }

    func title(lang: AppLanguage) -> String {
        guard lang == .en else { return title }
        switch self {
        case .returnKey: return "Return / Send"
        case .shiftReturn: return "New Line"
        case .escape: return "Escape"
        case .appSwitcher: return "Switch App"
        case .aiInlineEdit: return "AI Inline Edit"
        case .aiOpenChat: return "AI Chat Panel"
        case .aiAccept: return "Accept Code"
        case .toggleTerminal: return "Toggle Terminal"
        case .swapMicrophone: return "Switch Mic"
        case .commandA: return "Select All"
        case .commandC: return "Copy"
        case .commandV: return "Paste"
        case .commandZ: return "Undo"
        case .commandShiftZ: return "Redo"
        case .areaScreenshot: return "Area Capture"
        case .newTab: return "New Tab"
        case .spotlight: return "Spotlight"
        case .arrowUp: return "Arrow Up"
        case .arrowDown: return "Arrow Down"
        case .arrowLeft: return "Arrow Left"
        case .arrowRight: return "Arrow Right"
        case .deleteBackward: return "Delete"
        case .tab: return "Tab"
        case .space: return "Space"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        case .home: return "Home"
        case .end: return "End"
        case .showDesktop: return "Show Desktop"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "System Mute"
        case .playPause: return "Play / Pause"
        case .lockScreen: return "Lock Screen"
        case .sleep: return "Sleep"
        case .disabled: return "Disabled"
        case .custom: return "Custom"
        }
    }

    var shortBadge: String {
        switch self {
        case .returnKey: return "↩"
        case .shiftReturn: return "⇧↩"
        case .escape: return "⎋"
        case .appSwitcher: return "⌘⇥"
        case .aiInlineEdit: return "⌘K"
        case .aiOpenChat: return "⌘L"
        case .aiAccept: return "⌘↩"
        case .toggleTerminal: return "⌃`"
        case .swapMicrophone: return "M/C"
        case .commandA: return "⌘A"
        case .commandC: return "⌘C"
        case .commandV: return "⌘V"
        case .commandZ: return "⌘Z"
        case .commandShiftZ: return "⌘⇧Z"
        case .areaScreenshot: return "⌃⌘⇧4"
        case .newTab: return "⌘T"
        case .spotlight: return "⌘Space"
        case .arrowUp: return "↑"
        case .arrowDown: return "↓"
        case .arrowLeft: return "←"
        case .arrowRight: return "→"
        case .deleteBackward: return "⌫"
        case .tab: return "⇥"
        case .space: return "Space"
        case .pageUp: return "Pg↑"
        case .pageDown: return "Pg↓"
        case .home: return "↖"
        case .end: return "↘"
        case .showDesktop: return "F11"
        case .volumeUp: return "Vol+"
        case .volumeDown: return "Vol-"
        case .mute: return "Mute"
        case .playPause: return "⏯"
        case .lockScreen: return "⌃⌘Q"
        case .sleep: return "Sleep"
        case .disabled: return "Off"
        case .custom: return "REC"
        }
    }

    var keyboardSpec: (keyCode: CGKeyCode, flags: CGEventFlags)? {
        switch self {
        case .arrowUp: return (0x7E, [])
        case .arrowDown: return (0x7D, [])
        case .arrowLeft: return (0x7B, [])
        case .arrowRight: return (0x7C, [])
        case .returnKey: return (0x24, [])
        case .shiftReturn: return (0x24, [.maskShift])              // ⇧↩ 换行不发送
        case .escape: return (0x35, [])
        case .deleteBackward: return (0x33, [])
        case .tab: return (0x30, [])
        case .space: return (0x31, [])
        case .home: return (0x73, [])
        case .end: return (0x77, [])
        case .pageUp: return (0x74, [])
        case .pageDown: return (0x79, [])
        case .showDesktop: return (0x67, [.maskSecondaryFn])
        case .spotlight: return (0x31, [.maskCommand])
        case .aiInlineEdit: return (0x28, [.maskCommand])           // ⌘K
        case .aiOpenChat: return (0x25, [.maskCommand])             // ⌘L
        case .aiAccept: return (0x24, [.maskCommand])               // ⌘↩
        case .toggleTerminal: return (0x32, [.maskControl])         // ⌃`
        case .commandA: return (0x00, [.maskCommand])               // ⌘A
        case .commandC: return (0x08, [.maskCommand])
        case .commandV: return (0x09, [.maskCommand])
        case .commandZ: return (0x06, [.maskCommand])
        case .commandShiftZ: return (0x06, [.maskCommand, .maskShift]) // ⌘⇧Z
        case .areaScreenshot: return (0x15, [.maskControl, .maskCommand, .maskShift]) // ⌃⌘⇧4 截图至剪贴板
        case .newTab: return (0x11, [.maskCommand])                 // ⌘T
        case .lockScreen:
            return (0x0C, CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | CGEventFlags.maskCommand.rawValue | 0x12))
        default:
            return nil
        }
    }

    var mediaKeyCode: Int32? {
        switch self {
        case .volumeUp: return 0
        case .volumeDown: return 1
        case .mute: return 7
        case .playPause: return 16
        default: return nil
        }
    }

    func post(isDown: Bool) {
        guard self != .disabled, self != .swapMicrophone else { return }
        switch self {
        case .sleep:
            if isDown { SystemActionSupport.requestSleep() }
        case .appSwitcher:
            if isDown { AppSwitcherSession.shared.tapSwitcher() }
        default:
            if let spec = keyboardSpec {
                guard let source = CGEventSource(stateID: .hidSystemState),
                      let event = CGEvent(keyboardEventSource: source, virtualKey: spec.keyCode, keyDown: isDown) else {
                    return
                }
                event.flags = spec.flags
                event.setIntegerValueField(.eventSourceUserData, value: InputTrigger.syntheticMarker)
                event.post(tap: .cghidEventTap)
            } else if let media = mediaKeyCode, isDown {
                postMediaKey(media)
            }
        }
    }

    private func postMediaKey(_ key: Int32) {
        func send(state: Int32) {
            let data1 = Int((key << 16) | (state << 8))
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )?.cgEvent else { return }
            event.post(tap: .cghidEventTap)
        }
        send(state: 0xA)
        send(state: 0xB)
    }
}

/// 用户自定义录制的任意单键或组合键
struct RemoteCustomShortcut: Codable, Hashable {
    let keyCode: UInt16
    let flagsRawValue: UInt64
    let label: String

    func post(isDown: Bool) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: isDown) else {
            return
        }
        event.flags = CGEventFlags(rawValue: flagsRawValue)
        event.setIntegerValueField(.eventSourceUserData, value: InputTrigger.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }
}

/// 切换应用定时器会话：按住虚拟 ⌘ 并点按 Tab，停手 1 秒自动落地松开
final class AppSwitcherSession {
    static let shared = AppSwitcherSession()

    private var isActive = false
    private var commitWorkItem: DispatchWorkItem?

    private init() {}

    func tapSwitcher() {
        commitWorkItem?.cancel()
        if !isActive {
            postCommand(isDown: true)
            isActive = true
        }
        postTab()
        let work = DispatchWorkItem { [weak self] in
            self?.commit()
        }
        commitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func commit() {
        commitWorkItem?.cancel()
        commitWorkItem = nil
        guard isActive else { return }
        isActive = false
        postCommand(isDown: false)
    }

    private func postCommand(isDown: Bool) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: isDown) else { return }
        event.type = .flagsChanged
        event.flags = isDown ? .maskCommand : []
        event.setIntegerValueField(.eventSourceUserData, value: InputTrigger.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }

    private func postTab() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        for down in [true, false] {
            if let event = CGEvent(keyboardEventSource: source, virtualKey: 0x30, keyDown: down) {
                event.flags = .maskCommand
                event.setIntegerValueField(.eventSourceUserData, value: InputTrigger.syntheticMarker)
                event.post(tap: .cghidEventTap)
            }
        }
    }
}

enum SystemActionSupport {
    static func requestSleep() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"System Events\" to sleep"]
        try? process.run()
    }
}

/// 单套预设的完整按键档案（短按 + 长按第二功能 + 自定义录键），切换预设时互不覆盖
struct RemotePresetProfileSnapshot: Codable, Equatable {
    var targets: [String: RemoteMappingTarget]
    var customShortcuts: [String: RemoteCustomShortcut]
    var longPressTargets: [String: RemoteMappingTarget]
    var longPressCustomShortcuts: [String: RemoteCustomShortcut]

    static func defaults(for preset: RemoteMappingPreset) -> RemotePresetProfileSnapshot {
        RemotePresetProfileSnapshot(
            targets: preset.defaults,
            customShortcuts: [:],
            longPressTargets: preset.defaultLongPressTargets,
            longPressCustomShortcuts: [:]
        )
    }
}

/// 用户自定义加入「Vibe Coding 自动场景」的第三方应用条目
struct CustomAppSceneRule: Codable, Equatable, Hashable, Identifiable {
    var id: String { bundleID }
    let bundleID: String
    let appName: String
}

/// 预设方案
enum RemoteMappingPreset: String, CaseIterable, Identifiable, Codable {
    case vibe
    case office

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vibe: return "Vibe Coding 预设"
        case .office: return "日常办公"
        }
    }

    func title(lang: AppLanguage) -> String {
        guard lang == .en else { return title }
        switch self {
        case .vibe: return "Vibe Coding"
        case .office: return "Office / Media"
        }
    }

    var defaults: [String: RemoteMappingTarget] {
        switch self {
        case .vibe:
            return [
                "03": .arrowUp,
                "04": .arrowDown,
                "05": .arrowLeft,
                "06": .arrowRight,
                "07": .returnKey,
                "0B": .escape,
                "0A": .appSwitcher,
                "08": .commandZ,
                "0E": .aiInlineEdit,
                "0F": .toggleTerminal,
                "01": .lockScreen,
                "11": .swapMicrophone,
                "0C": .pageUp,
                "0D": .pageDown,
            ]
        case .office:
            return [
                "03": .arrowUp,
                "04": .arrowDown,
                "05": .arrowLeft,
                "06": .arrowRight,
                "07": .playPause,
                "0B": .deleteBackward,
                "0A": .showDesktop,
                "08": .mute,
                "0E": .spotlight,
                "0F": .disabled,
                "01": .sleep,
                "11": .swapMicrophone,
                "0C": .volumeUp,
                "0D": .volumeDown,
            ]
        }
    }

    /// 默认长按第二功能（空表示默认 0ms 瞬发，用户按需为任意功能键启用长按第二功能）
    var defaultLongPressTargets: [String: RemoteMappingTarget] {
        [:]
    }

    /// 根据当前前台激活应用的 Bundle ID 智能判定推荐预设（切回 G9NVibe 自身时返回 nil 不打扰用户编辑）
    static func recommendedPreset(forBundleID bundleID: String?, customCodingBundleIDs: Set<String> = []) -> RemoteMappingPreset? {
        guard let raw = bundleID?.lowercased(), !raw.isEmpty else { return nil }
        if raw == AppStorage.bundleIdentifier.lowercased() {
            return nil
        }
        if customCodingBundleIDs.contains(raw) {
            return .vibe
        }
        let codingPrefixes = [
            "com.todesktop.230313mzl4w4u92", // Cursor
            "com.microsoft.vscode",          // VS Code / Insiders
            "com.apple.dt.xcode",            // Xcode
            "com.jetbrains.",                // IntelliJ / PyCharm / WebStorm / GoLand 等全家桶
            "com.exafunction.windsurf",      // Windsurf
            "dev.zed.zed",                   // Zed
            "com.google.antigravity",        // Antigravity
            "com.trae.",                     // Trae
            "com.bytedance.trae",            // Trae CN
            "com.apple.terminal",            // Terminal
            "com.googlecode.iterm2",         // iTerm2
            "dev.warp.warp",                 // Warp
            "com.mitchellh.ghostty",         // Ghostty
            "org.alacritty",                 // Alacritty
            "net.kovidgoyal.kitty",          // Kitty
            "com.sublimetext.",              // Sublime Text
            "com.github.atom",               // Atom
        ]
        if codingPrefixes.contains(where: { raw.hasPrefix($0) }) || raw.contains("antigravity") || raw.contains("cursor") {
            return .vibe
        }
        return .office
    }
}

/// G9N9N 按键映射配置仓库（按预设独立保存短按/长按与自定义键位，支持前台应用自动切换）
final class RemoteMappingStore: ObservableObject {
    static let shared = RemoteMappingStore()

    @Published private(set) var enabled: Bool
    @Published private(set) var autoSwitchByApp: Bool
    @Published private(set) var activePreset: RemoteMappingPreset
    @Published private(set) var targets: [String: RemoteMappingTarget]
    @Published private(set) var customShortcuts: [String: RemoteCustomShortcut]
    @Published private(set) var longPressTargets: [String: RemoteMappingTarget]
    @Published private(set) var longPressCustomShortcuts: [String: RemoteCustomShortcut]
    /// 用户额外指定的「自动切至 Vibe Coding」应用列表
    @Published private(set) var customCodingApps: [CustomAppSceneRule]

    private var profileSnapshots: [String: RemotePresetProfileSnapshot] = [:]

    private init() {
        let initialPreset = RemoteMappingPreset(rawValue: AppStorage.remotePresetRaw) ?? .vibe
        var loadedSnapshots: [String: RemotePresetProfileSnapshot] = [:]
        if let data = AppStorage.remoteProfileSnapshotsData,
           let decoded = try? JSONDecoder().decode([String: RemotePresetProfileSnapshot].self, from: data) {
            loadedSnapshots = decoded
        }

        // 平滑迁移旧版单档案配置到当前激活预设
        if loadedSnapshots[initialPreset.rawValue] == nil {
            let legacyTargets: [String: RemoteMappingTarget]
            if let data = AppStorage.remoteMappingsData,
               let decoded = try? JSONDecoder().decode([String: RemoteMappingTarget].self, from: data) {
                legacyTargets = decoded
            } else {
                legacyTargets = initialPreset.defaults
            }
            let legacyCustom: [String: RemoteCustomShortcut]
            if let data = AppStorage.remoteCustomShortcutsData,
               let decoded = try? JSONDecoder().decode([String: RemoteCustomShortcut].self, from: data) {
                legacyCustom = decoded
            } else {
                legacyCustom = [:]
            }
            loadedSnapshots[initialPreset.rawValue] = RemotePresetProfileSnapshot(
                targets: legacyTargets,
                customShortcuts: legacyCustom,
                longPressTargets: initialPreset.defaultLongPressTargets,
                longPressCustomShortcuts: [:]
            )
        }

        let current = loadedSnapshots[initialPreset.rawValue] ?? .defaults(for: initialPreset)
        let loadedCustomApps: [CustomAppSceneRule]
        if let data = AppStorage.customCodingAppRulesData,
           let decoded = try? JSONDecoder().decode([CustomAppSceneRule].self, from: data) {
            loadedCustomApps = decoded
        } else {
            loadedCustomApps = []
        }

        enabled = AppStorage.remoteMappingEnabled
        autoSwitchByApp = AppStorage.autoSwitchPresetByApp
        activePreset = initialPreset
        profileSnapshots = loadedSnapshots
        targets = current.targets
        customShortcuts = current.customShortcuts
        longPressTargets = current.longPressTargets
        longPressCustomShortcuts = current.longPressCustomShortcuts
        customCodingApps = loadedCustomApps
    }

    var customCodingBundleIDSet: Set<String> {
        Set(customCodingApps.map { $0.bundleID.lowercased() })
    }

    func addCustomCodingApp(bundleID: String, appName: String) {
        let trimmedID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              trimmedID.lowercased() != AppStorage.bundleIdentifier.lowercased(),
              !customCodingApps.contains(where: { $0.bundleID.lowercased() == trimmedID.lowercased() }) else {
            return
        }
        customCodingApps.append(CustomAppSceneRule(bundleID: trimmedID, appName: appName))
        if let data = try? JSONEncoder().encode(customCodingApps) {
            AppStorage.customCodingAppRulesData = data
        }
    }

    func removeCustomCodingApp(bundleID: String) {
        customCodingApps.removeAll { $0.bundleID.lowercased() == bundleID.lowercased() }
        if let data = try? JSONEncoder().encode(customCodingApps) {
            AppStorage.customCodingAppRulesData = data
        }
    }

    func clearAllLongPressInCurrentPreset() {
        longPressTargets = [:]
        longPressCustomShortcuts = [:]
        persist()
    }

    /// 当前预设下已配置长按第二功能的按键数量
    var configuredLongPressCount: Int {
        RemoteProfiles.g9n9nButtons.filter { hasActiveLongPress(for: $0) }.count
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        AppStorage.remoteMappingEnabled = value
    }

    func setAutoSwitchByApp(_ value: Bool) {
        autoSwitchByApp = value
        AppStorage.autoSwitchPresetByApp = value
    }

    func target(for button: G9N9NButtonDefinition) -> RemoteMappingTarget {
        targets[button.id] ?? activePreset.defaults[button.id] ?? .disabled
    }

    func customShortcut(for button: G9N9NButtonDefinition) -> RemoteCustomShortcut? {
        customShortcuts[button.id]
    }

    func longPressTarget(for button: G9N9NButtonDefinition) -> RemoteMappingTarget {
        guard button.supportsLongPress else { return .disabled }
        return longPressTargets[button.id] ?? .disabled
    }

    func longPressCustomShortcut(for button: G9N9NButtonDefinition) -> RemoteCustomShortcut? {
        longPressCustomShortcuts[button.id]
    }

    /// 该按键是否配置了有效的长按第二功能
    func hasActiveLongPress(for button: G9N9NButtonDefinition) -> Bool {
        guard button.supportsLongPress else { return false }
        let lp = longPressTarget(for: button)
        if lp == .disabled { return false }
        if lp == .custom { return longPressCustomShortcuts[button.id] != nil }
        return true
    }

    func displayLabel(for button: G9N9NButtonDefinition, lang: AppLanguage = .zh) -> (text: String, isCustom: Bool) {
        let t = target(for: button)
        if t == .custom, let custom = customShortcuts[button.id] {
            let prefix = lang == .en ? "Custom" : "自定义"
            return ("\(prefix) · \(custom.label)", true)
        }
        return ("\(t.title(lang: lang)) (\(t.shortBadge))", false)
    }

    func longPressBadgeLabel(for button: G9N9NButtonDefinition, lang: AppLanguage = .zh) -> (text: String, isSet: Bool) {
        let t = longPressTarget(for: button)
        if t == .disabled {
            return (lang == .en ? "+ Hold" : "+ 长按", false)
        }
        if t == .custom, let custom = longPressCustomShortcuts[button.id] {
            let prefix = lang == .en ? "Hold" : "长按"
            return ("\(prefix) · \(custom.label)", true)
        }
        let prefix = lang == .en ? "Hold" : "长按"
        return ("\(prefix) · \(t.shortBadge)", true)
    }

    func setTarget(_ target: RemoteMappingTarget, for buttonID: String) {
        targets[buttonID] = target
        persist()
    }

    func setCustomShortcut(_ shortcut: RemoteCustomShortcut, for buttonID: String) {
        customShortcuts[buttonID] = shortcut
        targets[buttonID] = .custom
        persist()
    }

    func setLongPressTarget(_ target: RemoteMappingTarget, for buttonID: String) {
        if target == .disabled {
            longPressTargets.removeValue(forKey: buttonID)
        } else {
            longPressTargets[buttonID] = target
        }
        persist()
    }

    func setLongPressCustomShortcut(_ shortcut: RemoteCustomShortcut, for buttonID: String) {
        longPressCustomShortcuts[buttonID] = shortcut
        longPressTargets[buttonID] = .custom
        persist()
    }

    /// 无损切换预设：先保存当前预设的用户微调与长按配置，再加载目标预设（若从未修改过则使用出厂默认）
    func applyPreset(_ preset: RemoteMappingPreset) {
        guard activePreset != preset else { return }
        saveCurrentSnapshot()
        activePreset = preset
        AppStorage.remotePresetRaw = preset.rawValue
        let next = profileSnapshots[preset.rawValue] ?? .defaults(for: preset)
        targets = next.targets
        customShortcuts = next.customShortcuts
        longPressTargets = next.longPressTargets
        longPressCustomShortcuts = next.longPressCustomShortcuts
        persist()
    }

    func resetCurrentPreset() {
        let fresh = RemotePresetProfileSnapshot.defaults(for: activePreset)
        targets = fresh.targets
        customShortcuts = fresh.customShortcuts
        longPressTargets = fresh.longPressTargets
        longPressCustomShortcuts = fresh.longPressCustomShortcuts
        persist()
    }

    func post(button: G9N9NButtonDefinition, isDown: Bool) {
        let t = target(for: button)
        if t == .custom {
            customShortcuts[button.id]?.post(isDown: isDown)
        } else {
            t.post(isDown: isDown)
        }
    }

    /// 以完整点按（按下 + 30ms 松开）触发某键的短按或长按动作（专供配置了长按双功能的按键使用）
    func fireTap(button: G9N9NButtonDefinition, isLongPress: Bool) {
        let t = isLongPress ? longPressTarget(for: button) : target(for: button)
        guard t != .disabled, t != .swapMicrophone else { return }
        if t == .custom {
            let custom = isLongPress ? longPressCustomShortcuts[button.id] : customShortcuts[button.id]
            guard let custom else { return }
            custom.post(isDown: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                custom.post(isDown: false)
            }
        } else {
            t.post(isDown: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                t.post(isDown: false)
            }
        }
    }

    private func saveCurrentSnapshot() {
        profileSnapshots[activePreset.rawValue] = RemotePresetProfileSnapshot(
            targets: targets,
            customShortcuts: customShortcuts,
            longPressTargets: longPressTargets,
            longPressCustomShortcuts: longPressCustomShortcuts
        )
    }

    private func persist() {
        saveCurrentSnapshot()
        if let data = try? JSONEncoder().encode(profileSnapshots) {
            AppStorage.remoteProfileSnapshotsData = data
        }
        if let data = try? JSONEncoder().encode(targets) {
            AppStorage.remoteMappingsData = data
        }
        if let data = try? JSONEncoder().encode(customShortcuts) {
            AppStorage.remoteCustomShortcutsData = data
        }
    }
}
