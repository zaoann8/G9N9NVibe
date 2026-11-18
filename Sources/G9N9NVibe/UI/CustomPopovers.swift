import AppKit
import Carbon
import SwiftUI

/// 键盘按键名友好格式化（用于录制预览展示）
enum KeyLabelFormatter {
    static func format(event: NSEvent) -> (keyCode: UInt16, flags: CGEventFlags, label: String)? {
        let code = event.keyCode
        let cgFlags = cgEventFlags(from: event.modifierFlags)
        var parts: [String] = []
        if cgFlags.contains(.maskControl) { parts.append("⌃") }
        if cgFlags.contains(.maskAlternate) { parts.append("⌥") }
        if cgFlags.contains(.maskShift) { parts.append("⇧") }
        if cgFlags.contains(.maskCommand) { parts.append("⌘") }

        let keyName = readableKeyName(keyCode: code, charactersIgnoringModifiers: event.charactersIgnoringModifiers)
        parts.append(keyName)
        return (code, cgFlags, parts.joined(separator: " "))
    }

    static func cgEventFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        if flags.contains(.control) { out.insert(.maskControl) }
        if flags.contains(.option) { out.insert(.maskAlternate) }
        if flags.contains(.shift) { out.insert(.maskShift) }
        if flags.contains(.command) { out.insert(.maskCommand) }
        if flags.contains(.function) { out.insert(.maskSecondaryFn) }
        return out
    }

    private static func readableKeyName(keyCode: UInt16, charactersIgnoringModifiers: String?) -> String {
        switch keyCode {
        case 0x24: return "↩"
        case 0x30: return "⇥"
        case 0x31: return "Space"
        case 0x33: return "⌫"
        case 0x35: return "⎋"
        case 0x75: return "⌦"
        case 0x7E: return "↑"
        case 0x7D: return "↓"
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x74: return "Pg↑"
        case 0x79: return "Pg↓"
        case 0x73: return "Home"
        case 0x77: return "End"
        case 0x7A: return "F1"
        case 0x78: return "F2"
        case 0x63: return "F3"
        case 0x76: return "F4"
        case 0x60: return "F5"
        case 0x61: return "F6"
        case 0x62: return "F7"
        case 0x64: return "F8"
        case 0x65: return "F9"
        case 0x6D: return "F10"
        case 0x67: return "F11"
        case 0x6F: return "F12"
        default:
            if let ch = charactersIgnoringModifiers, !ch.isEmpty {
                return ch.uppercased()
            }
            return "Key(\(keyCode))"
        }
    }
}

/// 定制按键映射浮层：彻底替代系统丑陋原生下拉框，顶部内嵌实时录键 + 显式二次确认栏 + 4 分类紧凑双列网格
struct KeyActionPopoverView: View {
    let button: G9N9NButtonDefinition
    let currentTarget: RemoteMappingTarget
    let existingCustom: RemoteCustomShortcut?
    let lang: AppLanguage
    let palette: VibePalette
    let onPickTarget: (RemoteMappingTarget) -> Void
    let onConfirmCustom: (RemoteCustomShortcut) -> Void

    @State private var category: MappingActionCategory = .all
    @State private var isListening = false
    @State private var draftShortcut: RemoteCustomShortcut?
    @State private var eventMonitor: Any?

    private func t(_ zh: String, _ en: String) -> String {
        lang == .en ? en : zh
    }

    private var filteredActions: [RemoteMappingTarget] {
        let all = RemoteMappingTarget.allCases.filter { $0 != .custom }
        if category == .all { return all }
        return all.filter { $0.category == category }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 顶部原位录制区（含二次确认栏）
            recorderSection

            // 分类筛选胶囊（全热区可点击）
            HStack(spacing: 4) {
                ForEach(MappingActionCategory.allCases) { cat in
                    Button {
                        category = cat
                    } label: {
                        Text(cat.title(lang: lang))
                            .font(VibeFont.label(11.5, weight: .semibold))
                            .foregroundColor(category == cat ? palette.cardBg : palette.ink2)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(category == cat ? palette.ink1 : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 6)
            .overlay(Divider().background(palette.borderSoft), alignment: .bottom)

            // 紧凑双列动作网格
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {
                    ForEach(filteredActions) { item in
                        let selected = currentTarget == item
                        Button {
                            stopListening()
                            onPickTarget(item)
                        } label: {
                            HStack(spacing: 4) {
                                Text(item.title(lang: lang))
                                    .font(VibeFont.label(12, weight: selected ? .semibold : .regular))
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                Text(item.shortBadge)
                                    .font(VibeFont.mono(10.5))
                                    .opacity(0.68)
                            }
                            .foregroundColor(selected ? palette.brand : palette.ink1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(selected ? palette.brandSoft : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(selected ? palette.brandBorder : Color.clear, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(12)
        .frame(width: 326)
        .background(palette.cardBg)
        .onDisappear { stopListening() }
    }

    private var recorderSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isListening
                        ? (draftShortcut != nil ? t("已捕获按键，请确认保存", "Captured, confirm to save") : t("请直接按下键盘按键…", "Press any key combo…"))
                        : t("自定义任意按键 / 组合键", "Record Custom Shortcut"))
                        .font(VibeFont.label(12, weight: .semibold))
                        .foregroundColor(palette.ink1)
                    Text(isListening
                        ? (draftShortcut != nil ? t("如需修改，直接重新按键即可覆盖", "Press again to overwrite") : t("支持单键、⌘K、⌃⇧P 等任意组合", "Supports single keys or combos like ⌘K"))
                        : t("点此录制，捕获后需点击确认才会保存", "Click to record, then confirm to save"))
                        .font(VibeFont.caption(10.5))
                        .foregroundColor(palette.ink2)
                }
                Spacer(minLength: 4)
                Text(isListening ? (draftShortcut?.label ?? t("等待按键…", "Listening…")) : (existingCustom?.label ?? t("点击录制", "Record")))
                    .font(VibeFont.mono(11, weight: .semibold))
                    .foregroundColor(palette.brand)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.cardBg))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.borderMed, lineWidth: 1))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture { startListening() }

            if isListening {
                HStack {
                    Text(draftShortcut != nil ? t("确认绑定此快捷键？", "Bind this shortcut?") : t("监听中…", "Listening…"))
                        .font(VibeFont.caption(11))
                        .foregroundColor(palette.ink2)
                    Spacer()
                    Button {
                        stopListening()
                    } label: {
                        Text(t("取消", "Cancel"))
                            .font(VibeFont.label(11, weight: .semibold))
                            .foregroundColor(palette.ink1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(palette.cardBg))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.borderMed, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        if let draft = draftShortcut {
                            stopListening()
                            onConfirmCustom(draft)
                        }
                    } label: {
                        Text(t("确认保存", "Save"))
                            .font(VibeFont.label(11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(palette.brand.opacity(draftShortcut == nil ? 0.42 : 1.0)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(draftShortcut == nil)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(palette.cardBg.opacity(0.75))
                .overlay(Divider().background(palette.brandBorder), alignment: .top)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(isListening ? palette.brandSoft : palette.insetBg))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isListening ? palette.brand : palette.borderMed, style: StrokeStyle(lineWidth: 1.4, dash: isListening ? [] : [4, 3]))
        )
    }

    private func startListening() {
        stopListening()
        isListening = true
        draftShortcut = nil
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard let formatted = KeyLabelFormatter.format(event: event) else { return nil }
            draftShortcut = RemoteCustomShortcut(
                keyCode: formatted.keyCode,
                flagsRawValue: formatted.flags.rawValue,
                label: formatted.label
            )
            return nil
        }
    }

    private func stopListening() {
        isListening = false
        draftShortcut = nil
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

/// 定制语音触发键浮层（支持单按左/右修饰键或任意组合键 + 显式二次确认）
struct VoiceTriggerPopoverView: View {
    let currentShortcut: VoiceTriggerShortcut
    let lang: AppLanguage
    let palette: VibePalette
    let onConfirm: (VoiceTriggerShortcut) -> Void

    @State private var isListening = false
    @State private var draft: VoiceTriggerShortcut?
    @State private var eventMonitor: Any?

    private func t(_ zh: String, _ en: String) -> String {
        lang == .en ? en : zh
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isListening
                            ? (draft != nil ? t("已捕获触发键，请确认保存", "Captured, confirm to save") : t("请按下语音触发键…", "Press voice trigger key…"))
                            : t("自定义语音触发键", "Record Voice Trigger"))
                            .font(VibeFont.label(12, weight: .semibold))
                            .foregroundColor(palette.ink1)
                        Text(isListening
                            ? (draft != nil ? t("可继续按键重新覆盖", "Press again to overwrite") : t("支持单按左/右 ⌥ ⌘ ⌃ ⇧ 或任意组合键", "Supports Left/Right ⌥ ⌘ ⌃ ⇧ or combos"))
                            : t("点击后敲键盘录制，确认后生效", "Click to record, confirm to apply"))
                            .font(VibeFont.caption(10.5))
                            .foregroundColor(palette.ink2)
                    }
                    Spacer(minLength: 4)
                    Text(isListening ? (draft?.displayShortLabel(lang: lang) ?? t("等待按键…", "Listening…")) : (currentShortcut.isCustomRecorded ? currentShortcut.displayShortLabel(lang: lang) : t("点击录制", "Record")))
                        .font(VibeFont.mono(11, weight: .semibold))
                        .foregroundColor(palette.brand)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(palette.cardBg))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.borderMed, lineWidth: 1))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
                .onTapGesture { startListening() }

                if isListening {
                    HStack {
                        Text(draft != nil ? t("确认使用此触发键？", "Use this trigger key?") : t("监听中…", "Listening…"))
                            .font(VibeFont.caption(11))
                            .foregroundColor(palette.ink2)
                        Spacer()
                        Button {
                            stopListening()
                        } label: {
                            Text(t("取消", "Cancel"))
                                .font(VibeFont.label(11, weight: .semibold))
                                .foregroundColor(palette.ink1)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(palette.cardBg))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.borderMed, lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            if let draft {
                                stopListening()
                                onConfirm(draft)
                            }
                        } label: {
                            Text(t("确认保存", "Save"))
                                .font(VibeFont.label(11, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(palette.brand.opacity(draft == nil ? 0.42 : 1.0)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(draft == nil)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(palette.cardBg.opacity(0.75))
                    .overlay(Divider().background(palette.brandBorder), alignment: .top)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(isListening ? palette.brandSoft : palette.insetBg))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isListening ? palette.brand : palette.borderMed, style: StrokeStyle(lineWidth: 1.4, dash: isListening ? [] : [4, 3]))
            )

            Text(t("常用预设触发键", "Preset Triggers"))
                .font(VibeFont.label(11, weight: .semibold))
                .foregroundColor(palette.ink3)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)], spacing: 5) {
                ForEach(VoiceTriggerShortcut.presets, id: \.label) { preset in
                    let selected = !currentShortcut.isCustomRecorded && currentShortcut.label == preset.label
                    Button {
                        stopListening()
                        onConfirm(preset)
                    } label: {
                        HStack {
                            Text(preset.displayLabel(lang: lang))
                                .font(VibeFont.label(12, weight: selected ? .semibold : .regular))
                            Spacer()
                        }
                        .foregroundColor(selected ? palette.brand : palette.ink1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? palette.brandSoft : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? palette.brandBorder : Color.clear, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 316)
        .background(palette.cardBg)
        .onDisappear { stopListening() }
    }

    private func startListening() {
        stopListening()
        isListening = true
        draft = nil
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if event.type == .flagsChanged {
                if let mod = ModifierTriggerKey.from(keyCode: event.keyCode) {
                    draft = VoiceTriggerShortcut.customModifier(mod)
                }
                return nil
            }
            if let formatted = KeyLabelFormatter.format(event: event) {
                draft = VoiceTriggerShortcut.customCombo(
                    keyCode: formatted.keyCode,
                    flags: formatted.flags,
                    label: formatted.label
                )
            }
            return nil
        }
    }

    private func stopListening() {
        isListening = false
        draft = nil
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

/// 定制第三方语音输入法选择浮层
struct IMEPopoverView: View {
    let current: VoiceInputMethod
    let lang: AppLanguage
    let palette: VibePalette
    let onSelect: (VoiceInputMethod) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(lang == .en ? "Select Voice Input Tool" : "选择目标第三方语音工具")
                .font(VibeFont.label(11, weight: .semibold))
                .foregroundColor(palette.ink3)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)

            ForEach(VoiceInputMethod.allCases) { item in
                let selected = current == item
                Button {
                    onSelect(item)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title(lang: lang))
                                .font(VibeFont.label(12.5, weight: .semibold))
                            Text(item.subtitle(lang: lang))
                                .font(VibeFont.caption(10.5))
                                .foregroundColor(palette.ink3)
                        }
                        Spacer()
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                        }
                    }
                    .foregroundColor(selected ? palette.brand : palette.ink1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? palette.brandSoft : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? palette.brandBorder : Color.clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 256)
        .background(palette.cardBg)
    }
}
