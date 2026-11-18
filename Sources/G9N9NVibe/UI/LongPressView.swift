import SwiftUI

/// 页面 3：长按扩展（独立页面专门配置 8 枚功能键的「短按 + 长按 0.38s」双功能，宽敞 2 列大卡片布局）
struct LongPressView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: RemoteMappingStore
    let palette: VibePalette

    @State private var activePopoverKeyID: String?
    @State private var showClearAllConfirm = false

    private var supportedButtons: [G9N9NButtonDefinition] {
        RemoteProfiles.g9n9nButtons.filter { $0.supportsLongPress }
    }

    var body: some View {
        VStack(spacing: 14) {
            // 顶部说明与预设切换条
            headerCard

            // 主体：宽敞 2 列 × 4 行大卡片网格（8 枚功能键，每张卡片清晰对照短按与长按，空间充裕极易操作）
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    ForEach(supportedButtons) { button in
                        longPressCard(button)
                    }
                }
                .padding(.vertical, 2)
            }
            .opacity(store.enabled ? 1.0 : 0.48)
            .allowsHitTesting(store.enabled)

            // 底部温和提示栏
            footerBar
        }
        .alert(
            vm.t("确认清空当前预设的全部长按动作？", "Clear All Hold Actions in This Preset?"),
            isPresented: $showClearAllConfirm
        ) {
            Button(vm.t("取消", "Cancel"), role: .cancel) {}
            Button(vm.t("确认清空", "Clear All"), role: .destructive) {
                store.clearAllLongPressInCurrentPreset()
                vm.showToast(vm.t("已清空当前预设的长按扩展（全部恢复 0ms 瞬发）", "Cleared all hold actions in current preset"), positive: false)
            }
        } message: {
            Text(vm.t(
                "清空后所有按键的短按映射不受影响，未配长按的功能键将恢复按下瞬间 0ms 触发。",
                "Your tap mappings remain untouched. Cleared buttons return to instant 0ms tap response."
            ))
        }
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(palette.brandSoft)
                    .frame(width: 38, height: 38)
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(palette.brand)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(vm.t("短按 + 长按双功能扩展", "Tap + Hold Dual Actions"))
                        .font(VibeFont.title(14.5))
                        .foregroundColor(palette.ink1)
                    Text(vm.t("已配置 \(store.configuredLongPressCount) / \(supportedButtons.count)", "\(store.configuredLongPressCount) / \(supportedButtons.count) Active"))
                        .font(VibeFont.mono(10.5, weight: .semibold))
                        .foregroundColor(store.configuredLongPressCount > 0 ? palette.brand : palette.ink3)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(store.configuredLongPressCount > 0 ? palette.brandSoft : palette.insetBg))
                }
                Text(vm.t(
                    "按住任意功能键 0.38 秒触发第二动作；未设长按的键以及方向/音量键保持 0ms 按下瞬发。",
                    "Hold any function key for 0.38s to trigger a second action. Unconfigured & D-Pad/Vol keys fire in 0ms."
                ))
                .font(VibeFont.caption(11.5))
                .foregroundColor(palette.ink2)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            // 预设切换（与按键映射页同步，每套预设独立保存长按配置）
            HStack(spacing: 6) {
                ForEach(RemoteMappingPreset.allCases) { preset in
                    let active = store.activePreset == preset
                    Button {
                        store.applyPreset(preset)
                    } label: {
                        Text(preset.title(lang: vm.language))
                            .font(VibeFont.label(11.5, weight: .semibold))
                            .foregroundColor(active ? palette.cardBg : palette.ink2)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(active ? palette.ink1 : palette.insetBg))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(active ? palette.ink1 : palette.borderSoft, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.borderSoft, lineWidth: 1))
    }

    @ViewBuilder
    private func longPressCard(_ button: G9N9NButtonDefinition) -> some View {
        let isSet = store.hasActiveLongPress(for: button)
        let shortDisp = store.displayLabel(for: button, lang: vm.language)
        let lpTarget = store.longPressTarget(for: button)
        let lpCustom = store.longPressCustomShortcut(for: button)
        let lpText: String = {
            if !isSet {
                return vm.t("未设置（0ms 瞬发模式）", "Not Set (Instant 0ms Tap)")
            }
            if lpTarget == .custom, let lpCustom {
                return "\(vm.t("自定义", "Custom")) · \(lpCustom.label)"
            }
            return "\(lpTarget.title(lang: vm.language)) (\(lpTarget.shortBadge))"
        }()

        VStack(alignment: .leading, spacing: 11) {
            // 卡片顶行：大号键帽 + 名称 + 当前短按对照胶囊
            HStack(spacing: 10) {
                Text(button.badge)
                    .font(VibeFont.mono(11, weight: .bold))
                    .foregroundColor(isSet ? .white : palette.ink2)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(isSet ? palette.brand : palette.insetBg))

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(button.title(lang: vm.language))
                        .font(VibeFont.title(13.5))
                        .foregroundColor(palette.ink1)
                    Text("\(vm.t("短按", "Tap")): \(shortDisp.text)")
                        .font(VibeFont.caption(11))
                        .foregroundColor(palette.ink2)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isSet {
                    Button {
                        store.setLongPressTarget(.disabled, for: button.id)
                    } label: {
                        Text(vm.t("清除", "Clear"))
                            .font(VibeFont.label(11, weight: .semibold))
                            .foregroundColor(palette.ink3)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3.5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(palette.insetBg))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(vm.t("清除长按动作并恢复 0ms 瞬发", "Clear hold action"))
                } else {
                    Text(vm.t("未启用", "Off"))
                        .font(VibeFont.label(10.5, weight: .medium))
                        .foregroundColor(palette.ink3)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(palette.insetBg))
                }
            }

            // 卡片底行：宽敞长按动作选择器
            HStack(spacing: 8) {
                Text(vm.t("长按 0.4s", "Hold 0.4s"))
                    .font(VibeFont.label(11.5, weight: .semibold))
                    .foregroundColor(isSet ? palette.brand : palette.ink2)
                    .frame(width: 66, alignment: .leading)

                CustomSelectPill(
                    text: lpText,
                    isHighlighted: isSet,
                    palette: palette,
                    minWidth: 160
                ) {
                    activePopoverKeyID = button.id
                }
                .frame(maxWidth: .infinity)
                .popover(
                    isPresented: Binding(
                        get: { activePopoverKeyID == button.id },
                        set: { if !$0 { activePopoverKeyID = nil } }
                    ),
                    arrowEdge: .bottom
                ) {
                    KeyActionPopoverView(
                        button: button,
                        currentTarget: lpTarget,
                        existingCustom: lpCustom,
                        lang: vm.language,
                        palette: palette,
                        onPickTarget: { target in
                            store.setLongPressTarget(target, for: button.id)
                            activePopoverKeyID = nil
                        },
                        onConfirmCustom: { custom in
                            store.setLongPressCustomShortcut(custom, for: button.id)
                            activePopoverKeyID = nil
                        }
                    )
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 13).fill(palette.cardBg))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(isSet ? palette.brandBorder : palette.borderSoft, lineWidth: isSet ? 1.2 : 1)
        )
    }

    private var footerBar: some View {
        HStack {
            Text(vm.t(
                "推荐搭配示例：确认键 短按「回车发送」+ 长按「换行不发送 (⇧↩)」；静音键 短按「撤销」+ 长按「重做 (⌘⇧Z)」",
                "Tip: Select Tap = Return / Hold = New Line (⇧↩); Mute Tap = Undo / Hold = Redo (⌘⇧Z)"
            ))
            .font(VibeFont.caption(11.5))
            .foregroundColor(palette.ink2)
            .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                showClearAllConfirm = true
            } label: {
                Text(vm.t("清空当前预设长按", "Clear All Hold"))
                    .font(VibeFont.label(11.5, weight: .semibold))
                    .foregroundColor(store.configuredLongPressCount > 0 ? palette.brand : palette.ink3)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(store.configuredLongPressCount > 0 ? palette.brandSoft : palette.insetBg))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.configuredLongPressCount == 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.borderSoft, lineWidth: 1))
    }
}
