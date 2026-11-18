import SwiftUI

/// 页面 2：按键映射（顶部自定义语音触发键条 + 左侧 1:1 纯矢量 G9N9N 遥控器 + 右侧全 15 键双向联动清单）
struct KeyMappingView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: RemoteMappingStore
    let palette: VibePalette

    @State private var showTriggerPopover = false
    @State private var activeActionPopoverKeyID: String?
    @State private var showResetConfirm = false

    var body: some View {
        VStack(spacing: 14) {
            // 顶部语音输入触发键条（完全支持自定义录制 + 二次确认）
            triggerStrip

            // 主体双栏：左 1:1 矢量遥控器 + 右全 15 键自定义清单
            HStack(spacing: 14) {
                remoteShowcaseCard
                    .frame(width: 266)

                mappingListCard
            }
        }
        .alert(
            vm.t("确认恢复默认按键映射？", "Reset Key Mappings to Default?"),
            isPresented: $showResetConfirm
        ) {
            Button(vm.t("取消", "Cancel"), role: .cancel) {}
            Button(vm.t("确认恢复", "Reset"), role: .destructive) {
                store.resetCurrentPreset()
                vm.showToast(vm.t("✓ 已恢复当前预设的默认按键映射", "✓ Key mappings reset to default"))
            }
        } message: {
            Text(vm.t(
                "此操作将把当前预设下的全部 14 个按键恢复为出厂默认动作，并覆盖已自定义的快捷键绑定。",
                "This resets all 14 remappable buttons in the current preset back to defaults."
            ))
        }
    }

    private var triggerStrip: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(palette.brandSoft)
                    .frame(width: 34, height: 34)
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(palette.brand)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.t("语音输入触发键", "Voice Trigger Shortcut"))
                    .font(VibeFont.title(13.5))
                    .foregroundColor(palette.ink1)
                Text(vm.t(
                    "遥控器黑色语音键与电脑键盘均使用此快捷键，支持自由录制任意单键、左右修饰键或组合键。",
                    "Used by both the remote voice button and your keyboard. Supports any modifier or custom combo."
                ))
                    .font(VibeFont.caption(11.5))
                    .foregroundColor(palette.ink2)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            CustomSelectPill(
                text: vm.triggerShortcut.isCustomRecorded
                    ? "\(vm.t("自定义", "Custom")) · \(vm.triggerShortcut.displayLabel(lang: vm.language))"
                    : vm.triggerShortcut.displayLabel(lang: vm.language),
                isHighlighted: vm.triggerShortcut.isCustomRecorded,
                palette: palette,
                minWidth: 152
            ) {
                showTriggerPopover.toggle()
            }
            .popover(isPresented: $showTriggerPopover, arrowEdge: .bottom) {
                VoiceTriggerPopoverView(currentShortcut: vm.triggerShortcut, lang: vm.language, palette: palette) { chosen in
                    vm.selectTriggerShortcut(chosen)
                    showTriggerPopover = false
                }
            }

            // 长按说话 / 短按开关（全热区可点）
            HStack(spacing: 2) {
                ForEach(InputTriggerMode.allCases) { mode in
                    let active = vm.triggerMode == mode
                    Button {
                        vm.selectTriggerMode(mode)
                    } label: {
                        Text(vm.language == .en ? (mode == .hold ? "Hold" : "Toggle") : mode.title)
                            .font(VibeFont.label(11.5, weight: .semibold))
                            .foregroundColor(active ? palette.ink1 : palette.ink2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(active ? palette.cardBg : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.insetBg))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.borderSoft, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.borderSoft, lineWidth: 1))
    }

    private var remoteShowcaseCard: some View {
        VStack(spacing: 8) {
            HStack {
                Text("G9N9N Remote")
                    .font(VibeFont.title(12.5))
                    .foregroundColor(palette.ink1)
                Spacer()
                // 明确展示硬件真实蓝牙电量（未连接显示 --%，已连读取 0x180F 电池服务百分比）
                let level = vm.remoteBatteryLevel
                let isLow = (level ?? 100) < 20
                let batIcon: String = {
                    guard let pct = level else { return "battery.0" }
                    if pct >= 85 { return "battery.100" }
                    if pct >= 55 { return "battery.75" }
                    if pct >= 30 { return "battery.50" }
                    return "battery.25"
                }()
                let batText: String = {
                    if let pct = level { return vm.t("电量 \(pct)%", "Bat \(pct)%") }
                    if vm.bleConnected || vm.hidConnected { return vm.t("电量读取中", "Bat …") }
                    return vm.t("电量 --%", "Bat --%")
                }()
                HStack(spacing: 4) {
                    Image(systemName: batIcon)
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(batText)
                        .font(VibeFont.mono(10, weight: .semibold))
                }
                .foregroundColor(level == nil ? palette.ink3 : (isLow ? palette.amber : palette.macGreen))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(level == nil ? palette.insetBg : (isLow ? palette.amberSoft : palette.macGreenSoft)))
            }

            G9N9NVectorView(
                selectedKeyID: $vm.selectedButtonID,
                isVoiceActive: vm.isRecording || vm.voiceKeyLivePulse || vm.isTestSpeaking,
                isConnected: vm.bleConnected || vm.hidConnected,
                isLedPulsing: vm.remoteLedPulse,
                palette: palette
            ) { keyID in
                vm.selectedButtonID = keyID
                vm.triggerRemoteLedPulse()
                if keyID == "voice" {
                    vm.onTestSpeakRequested?()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(vm.t("点击左侧键帽与右侧清单高亮联动", "Click keys to highlight with list"))
                .font(VibeFont.caption(11))
                .foregroundColor(palette.ink3)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.borderSoft, lineWidth: 1))
    }

    private var mappingListCard: some View {
        VStack(spacing: 0) {
            // 顶部预设与启用映射总开关（长按与自动场景已拆分至独立 Tab，此处保持极简清爽）
            HStack(spacing: 8) {
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
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 7).fill(active ? palette.ink1 : palette.insetBg))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(active ? palette.ink1 : palette.borderSoft, lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Text(vm.t("启用映射", "Enable Map"))
                        .font(VibeFont.label(12, weight: .medium))
                        .foregroundColor(palette.ink2)
                    CeramicToggle(isOn: store.enabled, tint: palette.brand, palette: palette) {
                        let next = !store.enabled
                        store.setEnabled(next)
                        vm.onMappingEnabledChanged?(next)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(Divider().background(palette.borderSoft), alignment: .bottom)

            // 15 键手动滚动列表（移除自动随光标跳动滚动，完全由用户手动滚轮滑动）
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(RemoteProfiles.g9n9nButtons) { button in
                        keyMappingRow(button)
                            .id(button.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .opacity(store.enabled ? 1.0 : 0.45)
            .allowsHitTesting(store.enabled)

            // 底部提示与恢复默认
            HStack {
                Text(vm.t("按预设独立保存 · 如需配置长按双功能或自动切预设，请切换顶部对应标签页", "Saved per preset · Use Hold Keys or Auto App tabs for advanced rules"))
                    .font(VibeFont.caption(11))
                    .foregroundColor(palette.ink3)
                Spacer()
                Button {
                    showResetConfirm = true
                } label: {
                    Text(vm.t("恢复默认", "Reset"))
                        .font(VibeFont.label(12, weight: .semibold))
                        .foregroundColor(palette.brand)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(palette.brandSoft))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .overlay(Divider().background(palette.borderSoft), alignment: .top)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.borderSoft, lineWidth: 1))
    }

    @ViewBuilder
    private func keyMappingRow(_ button: G9N9NButtonDefinition) -> some View {
        let isSelected = vm.selectedButtonID == button.id
        HStack(spacing: 12) {
            // 固定宽度左列，确保右侧所有下拉选择框严格垂直对齐一条直线
            HStack(spacing: 10) {
                Text(button.badge)
                    .font(VibeFont.mono(10, weight: .bold))
                    .foregroundColor(isSelected ? .white : palette.ink2)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? palette.brand : palette.insetBg))
                Text(button.title(lang: vm.language))
                    .font(VibeFont.label(13, weight: .semibold))
                    .foregroundColor(palette.ink1)
                    .lineLimit(1)
            }
            .frame(width: 118, alignment: .leading)

            if button.isVoiceKey {
                CustomSelectPill(
                    text: "\(vm.t("语音", "Voice")) · \(vm.triggerShortcut.displayShortLabel(lang: vm.language)) (\(vm.language == .en ? (vm.triggerMode == .hold ? "Hold" : "Tap") : vm.triggerMode.title))",
                    isHighlighted: vm.triggerShortcut.isCustomRecorded,
                    palette: palette,
                    minWidth: 200
                ) {
                    showTriggerPopover = true
                }
                .frame(maxWidth: .infinity)
            } else {
                let disp = store.displayLabel(for: button, lang: vm.language)
                CustomSelectPill(
                    text: disp.text,
                    isHighlighted: disp.isCustom,
                    palette: palette,
                    minWidth: 200
                ) {
                    vm.selectedButtonID = button.id
                    activeActionPopoverKeyID = button.id
                }
                .frame(maxWidth: .infinity)
                .popover(
                    isPresented: Binding(
                        get: { activeActionPopoverKeyID == button.id },
                        set: { if !$0 { activeActionPopoverKeyID = nil } }
                    ),
                    arrowEdge: .trailing
                ) {
                    KeyActionPopoverView(
                        button: button,
                        currentTarget: store.target(for: button),
                        existingCustom: store.customShortcut(for: button),
                        lang: vm.language,
                        palette: palette,
                        onPickTarget: { target in
                            store.setTarget(target, for: button.id)
                            activeActionPopoverKeyID = nil
                        },
                        onConfirmCustom: { custom in
                            store.setCustomShortcut(custom, for: button.id)
                            activeActionPopoverKeyID = nil
                        }
                    )
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(isSelected ? palette.brandSoft : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(isSelected ? palette.brandBorder : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            vm.selectedButtonID = button.id
        }
    }
}
