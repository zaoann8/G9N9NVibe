import Foundation

/// 全局收音路由策略：实现 Mac 麦克风与遥控器麦克风的无冲突融合
enum MicRoutingPolicy: String, CaseIterable, Codable, Identifiable {
    /// 仅电脑麦克风（未装驱动时零延迟直通；已装驱动时 0ms 透传给虚拟声卡，豆包无需改设置）
    case macOnly
    /// 智能随动（已装驱动推荐默认：按键盘用电脑麦，按遥控器用遥控器麦，零回声）
    case smartByTriggerSource
    /// 仅遥控器麦克风（屏蔽桌面键盘噪音）
    case remoteOnly
    /// 双麦合并（Mac 麦自动延迟 120ms 与遥控器声音对齐混合）
    case dualMix

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macOnly: return "仅电脑麦"
        case .smartByTriggerSource: return "智能随动"
        case .remoteOnly: return "仅遥控器麦"
        case .dualMix: return "双麦合并"
        }
    }

    var subtitle: String {
        switch self {
        case .macOnly: return "零延迟直通，不占 AirPods 通道"
        case .smartByTriggerSource: return "按键盘用电脑麦，按遥控器用遥控器麦"
        case .remoteOnly: return "屏蔽桌面键盘声与环境噪音"
        case .dualMix: return "Mac 麦延迟 120ms 与遥控器对齐合并"
        }
    }

    func title(lang: AppLanguage) -> String {
        guard lang == .en else { return title }
        switch self {
        case .macOnly: return "Mac Mic"
        case .smartByTriggerSource: return "Smart Auto"
        case .remoteOnly: return "Remote Mic"
        case .dualMix: return "Dual Mix"
        }
    }

    func subtitle(lang: AppLanguage) -> String {
        guard lang == .en else { return subtitle }
        switch self {
        case .macOnly: return "Zero latency, keeps AirPods hi-fi"
        case .smartByTriggerSource: return "Mac mic on keyboard, remote mic on remote"
        case .remoteOnly: return "Blocks keyboard & desk noise"
        case .dualMix: return "Aligns Mac mic (+120ms) with remote"
        }
    }

    /// 是否需要内置虚拟驱动才能生效
    var requiresDriver: Bool {
        self != .macOnly
    }
}

/// 界面显示语言（支持一键无刷新中英文切换）
enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case zh
    case en

    var id: String { rawValue }

    var toggleLabel: String {
        self == .zh ? "EN" : "中"
    }
}

/// 界面主题偏好
enum AppThemePreference: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
}

/// 遥控器近场/标准/远场 3 档实时收音灵敏度（直接作用于 ADPCM 解码后的线性 DSP 增益）
enum RemoteMicGainPreset: String, CaseIterable, Codable, Identifiable {
    case near
    case standard
    case far

    var id: String { rawValue }

    /// 线性放大倍率（+14 dB / +20 dB / +26 dB）
    var linearGain: Float {
        switch self {
        case .near: return 5.0
        case .standard: return 10.0
        case .far: return 20.0
        }
    }

    var dbLabel: String {
        switch self {
        case .near: return "+14dB"
        case .standard: return "+20dB"
        case .far: return "+26dB"
        }
    }

    func title(lang: AppLanguage) -> String {
        switch self {
        case .near: return lang == .en ? "Near" : "近场"
        case .standard: return lang == .en ? "Std" : "标准"
        case .far: return lang == .en ? "Far" : "远场"
        }
    }
}

/// 集中管理 UserDefaults 配置持久化
enum AppStorage {
    static let bundleIdentifier = "io.github.g9n9n-vibe"
    static let virtualDriverDeviceName = "G9N9N-Vibe Mic 2ch"
    static let virtualDriverDeviceUID = "io.github.g9n9n-vibe.mic2ch.uid"
    static let virtualDriverBundleName = "G9N9NVibeMic.driver"

    private static let defaults = UserDefaults.standard

    private enum Keys {
        static let micPolicy = "g9n9n.micRoutingPolicy"
        static let voiceInputMethod = "g9n9n.voiceInputMethod"
        static let voiceTriggerShortcut = "g9n9n.voiceTriggerShortcut"
        static let triggerMode = "g9n9n.inputTriggerMode"
        static let savedOriginalMicUID = "g9n9n.savedOriginalInputDeviceUID"
        static let theme = "g9n9n.themePreference"
        static let remoteMappingEnabled = "g9n9n.remoteMappingEnabled"
        static let remoteMappings = "g9n9n.remoteMappings"
        static let remoteCustomShortcuts = "g9n9n.remoteCustomShortcuts"
        static let remotePreset = "g9n9n.remotePreset"
        static let savedRemoteUUID = "g9n9n.savedPeripheralUUID"
        static let language = "g9n9n.appLanguage"
        static let onboardingDone = "g9n9n.onboardingCompleted.v1"
        static let remoteMicGainPreset = "g9n9n.remoteMicGainPreset"
        static let autoSwitchPresetByApp = "g9n9n.autoSwitchPresetByApp"
        static let remoteProfileSnapshots = "g9n9n.remoteProfileSnapshots.v1"
        static let customCodingAppRules = "g9n9n.customCodingAppRules.v1"
        static let lastUpdateCheckDate = "g9n9n.lastUpdateCheckDate"
        static let lastLaunchedVersion = "g9n9n.lastLaunchedVersion"
    }

    static var micPolicy: MicRoutingPolicy {
        get {
            guard let raw = defaults.string(forKey: Keys.micPolicy),
                  let policy = MicRoutingPolicy(rawValue: raw) else {
                return .macOnly
            }
            return policy
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.micPolicy)
        }
    }

    static var voiceInputMethodRaw: String? {
        get { defaults.string(forKey: Keys.voiceInputMethod) }
        set { defaults.set(newValue, forKey: Keys.voiceInputMethod) }
    }

    static var voiceTriggerShortcut: VoiceTriggerShortcut {
        get {
            guard let data = defaults.data(forKey: Keys.voiceTriggerShortcut),
                  let decoded = try? JSONDecoder().decode(VoiceTriggerShortcut.self, from: data) else {
                return .rightOption
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.voiceTriggerShortcut)
            }
        }
    }

    static var inputTriggerMode: InputTriggerMode {
        get {
            guard let raw = defaults.string(forKey: Keys.triggerMode),
                  let mode = InputTriggerMode(rawValue: raw) else {
                return .hold
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.triggerMode)
        }
    }

    static var savedOriginalInputDeviceUID: String? {
        get { defaults.string(forKey: Keys.savedOriginalMicUID) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Keys.savedOriginalMicUID)
            } else {
                defaults.removeObject(forKey: Keys.savedOriginalMicUID)
            }
        }
    }

    static var themePreference: AppThemePreference {
        get {
            guard let raw = defaults.string(forKey: Keys.theme),
                  let pref = AppThemePreference(rawValue: raw) else {
                return .light
            }
            return pref
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.theme)
        }
    }

    static var remoteMappingEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.remoteMappingEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.remoteMappingEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.remoteMappingEnabled) }
    }

    static var remoteMappingsData: Data? {
        get { defaults.data(forKey: Keys.remoteMappings) }
        set { defaults.set(newValue, forKey: Keys.remoteMappings) }
    }

    static var remoteCustomShortcutsData: Data? {
        get { defaults.data(forKey: Keys.remoteCustomShortcuts) }
        set { defaults.set(newValue, forKey: Keys.remoteCustomShortcuts) }
    }

    static var remotePresetRaw: String {
        get { defaults.string(forKey: Keys.remotePreset) ?? "vibe" }
        set { defaults.set(newValue, forKey: Keys.remotePreset) }
    }

    static var savedPeripheralUUID: String? {
        get { defaults.string(forKey: Keys.savedRemoteUUID) }
        set { defaults.set(newValue, forKey: Keys.savedRemoteUUID) }
    }

    static var language: AppLanguage {
        get {
            guard let raw = defaults.string(forKey: Keys.language),
                  let lang = AppLanguage(rawValue: raw) else {
                return .zh
            }
            return lang
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.language)
        }
    }

    static var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Keys.onboardingDone) }
        set { defaults.set(newValue, forKey: Keys.onboardingDone) }
    }

    static var remoteMicGainPreset: RemoteMicGainPreset {
        get {
            guard let raw = defaults.string(forKey: Keys.remoteMicGainPreset),
                  let preset = RemoteMicGainPreset(rawValue: raw) else {
                return .standard
            }
            return preset
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.remoteMicGainPreset)
        }
    }

    static var autoSwitchPresetByApp: Bool {
        get { defaults.bool(forKey: Keys.autoSwitchPresetByApp) }
        set { defaults.set(newValue, forKey: Keys.autoSwitchPresetByApp) }
    }

    static var remoteProfileSnapshotsData: Data? {
        get { defaults.data(forKey: Keys.remoteProfileSnapshots) }
        set { defaults.set(newValue, forKey: Keys.remoteProfileSnapshots) }
    }

    static var customCodingAppRulesData: Data? {
        get { defaults.data(forKey: Keys.customCodingAppRules) }
        set { defaults.set(newValue, forKey: Keys.customCodingAppRules) }
    }

    static var lastUpdateCheckDate: Date? {
        get { defaults.object(forKey: Keys.lastUpdateCheckDate) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastUpdateCheckDate) }
    }

    static var lastLaunchedVersion: String? {
        get { defaults.string(forKey: Keys.lastLaunchedVersion) }
        set { defaults.set(newValue, forKey: Keys.lastLaunchedVersion) }
    }

    /// GitHub 仓库标识（格式 "owner/repo"，由 GitHub Actions 打包时自动写入 Info.plist）
    static var githubRepository: String {
        (Bundle.main.object(forInfoDictionaryKey: "G9NVibeGitHubRepo") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var appVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }
}
