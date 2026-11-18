import AppKit
import Foundation

/// 支持驱动的第三方语音输入工具
enum VoiceInputMethod: String, CaseIterable, Identifiable, Codable {
    case doubao
    case wetype
    case generic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .doubao: return "豆包输入法"
        case .wetype: return "微信输入法"
        case .generic: return "系统听写 / 其他"
        }
    }

    var shortName: String {
        switch self {
        case .doubao: return "豆包"
        case .wetype: return "微信输入法"
        case .generic: return "语音输入"
        }
    }

    var subtitle: String {
        switch self {
        case .doubao: return "支持独立选择麦克风设备"
        case .wetype: return "自动跟随系统默认输入并安全恢复"
        case .generic: return "通用第三方语音快捷键模式"
        }
    }

    func title(lang: AppLanguage) -> String {
        guard lang == .en else { return title }
        switch self {
        case .doubao: return "Doubao IME"
        case .wetype: return "WeType IME"
        case .generic: return "Dictation / Other"
        }
    }

    func subtitle(lang: AppLanguage) -> String {
        guard lang == .en else { return subtitle }
        switch self {
        case .doubao: return "Supports dedicated microphone selection"
        case .wetype: return "Follows system default mic & auto-restores"
        case .generic: return "Universal shortcut-based voice tools"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .doubao: return "com.bytedance.inputmethod.doubaoime"
        case .wetype: return "com.tencent.inputmethod.wetype"
        case .generic: return nil
        }
    }

    /// 是否需要跟随系统默认输入设备
    var followsSystemDefaultInput: Bool {
        self == .wetype || self == .generic
    }

    var isInstalled: Bool {
        guard let bid = bundleIdentifier else { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) != nil
    }

    static var current: VoiceInputMethod {
        if let raw = AppStorage.voiceInputMethodRaw,
           let stored = VoiceInputMethod(rawValue: raw) {
            return stored
        }
        if !doubao.isInstalled, wetype.isInstalled {
            return .wetype
        }
        return .doubao
    }

    static func select(_ method: VoiceInputMethod) {
        AppStorage.voiceInputMethodRaw = method.rawValue
    }
}
