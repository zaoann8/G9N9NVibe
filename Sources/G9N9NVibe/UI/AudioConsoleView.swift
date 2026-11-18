import SwiftUI

/// 页面 1：音频控制台（4 档策略条 + 2→1 汇聚声道布局 + 40 线光柱 + 3×2 权限体检网格）
struct AudioConsoleView: View {
    @ObservedObject var vm: AppViewModel
    let palette: VibePalette

    @State private var showImePopover = false
    @State private var showUninstallConfirm = false

    var body: some View {
        GeometryReader { geo in
            // 平滑自适应比例：默认窗口 1.0 完整舒展绝不遮挡，拉大窗口时模块尺寸、微光柱与字号同步优雅放大铺满全屏
            let scale = min(1.22, max(1.0, min(geo.size.width / 880.0, geo.size.height / 610.0)))
            let rightWidth = max(336, min(480, geo.size.width * 0.37))
            let barHeight = 13.0 * scale

            VStack(spacing: 12 * scale) {
                // 顶部 4 档策略条 + 一键关闭双麦
                policyStrip(scale: scale)

                // 2 -> 1 汇聚声道区：横向 63% / 37% 满屏舒展，纵向随窗口高度同步放大且内部均匀呼吸
                HStack(spacing: 14 * scale) {
                    VStack(spacing: 12 * scale) {
                        macChannelCard(scale: scale, barHeight: barHeight)
                        remoteChannelCard(scale: scale, barHeight: barHeight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    outputHubCard(scale: scale, barHeight: barHeight)
                        .frame(width: rightWidth)
                        .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 底部 3 x 2 高辨识度语义自检状态方阵（随窗口适度舒展）
                healthSection(scale: scale)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .alert(
            vm.t("确认卸载内置音频驱动？", "Uninstall Built-in Audio Driver?"),
            isPresented: $showUninstallConfirm
        ) {
            Button(vm.t("取消", "Cancel"), role: .cancel) {}
            Button(vm.t("确认卸载", "Uninstall"), role: .destructive) {
                vm.onRequestUninstallDriver?()
            }
        } message: {
            Text(vm.t(
                "卸载将移除 G9N9N-Vibe Mic 虚拟声卡并短暂重载系统音频服务（约 1 秒），随后自动回到仅电脑麦直通模式。确定继续吗？",
                "This removes the G9N9N-Vibe Mic virtual driver and briefly restarts macOS coreaudiod (~1s), returning to Mac mic direct mode."
            ))
        }
    }

    private func policyStrip(scale: CGFloat) -> some View {
        HStack(spacing: 8 * scale) {
            HStack(spacing: 2) {
                ForEach(MicRoutingPolicy.allCases) { p in
                    let active = !vm.isAllMicsClosed && vm.micPolicy == p
                    Button {
                        vm.selectPolicy(p)
                    } label: {
                        HStack(spacing: 5) {
                            Text(p.title(lang: vm.language))
                                .font(VibeFont.label(12 * scale, weight: .semibold))
                            if p == .smartByTriggerSource {
                                Text(vm.t("推荐", "Best"))
                                    .font(VibeFont.label(9.5 * scale, weight: .semibold))
                                    .foregroundColor(palette.brand)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(palette.brandSoft))
                            }
                        }
                        .foregroundColor(active ? palette.ink1 : palette.ink2)
                        .padding(.horizontal, 11 * scale)
                        .padding(.vertical, 5 * scale)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(active ? palette.cardBg : Color.clear)
                                .shadow(color: active ? Color.black.opacity(0.08) : .clear, radius: 2, y: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.insetBg))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.borderSoft, lineWidth: 1))

            // 一键关闭 / 恢复双麦快捷按钮（全热区可点，关闭后系统默认麦完全还原不受接管）
            Button {
                vm.toggleMuteAll()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: vm.isAllMicsClosed ? "mic.slash.fill" : "mic.slash")
                        .font(.system(size: 11 * scale, weight: .semibold))
                    Text(vm.isAllMicsClosed
                        ? vm.t("已关双麦", "Muted")
                        : vm.t("关闭双麦", "Mute All"))
                        .font(VibeFont.label(11.5 * scale, weight: .semibold))
                }
                .foregroundColor(vm.isAllMicsClosed ? palette.brand : palette.ink2)
                .padding(.horizontal, 10 * scale)
                .frame(height: 30 * scale)
                .background(RoundedRectangle(cornerRadius: 9).fill(vm.isAllMicsClosed ? palette.brandSoft : palette.cardBg))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(vm.isAllMicsClosed ? palette.brandBorder : palette.borderMed, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(vm.t("一键关闭两路麦克风并保持系统原物理麦不受接管", "Mute both microphones and keep system mic untouched"))

            Spacer(minLength: 4)

            Text(policyHintText)
                .font(VibeFont.caption(11.5 * scale))
                .foregroundColor(palette.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var policyHintText: String {
        if vm.isAllMicsClosed {
            return vm.t("双麦已暂停 · 系统麦完全未接管", "Both mics muted · System mic untouched")
        }
        if !vm.driverInstalled {
            return vm.t("电脑麦直通 · 启用声卡后解锁遥控器麦", "Mac mic direct · Enable driver for remote mic")
        }
        switch vm.micPolicy {
        case .macOnly: return vm.t("电脑麦直通 · 系统默认麦完全不受接管", "Mac mic direct · System mic untouched")
        case .smartByTriggerSource: return vm.t("按键盘用电脑麦，按遥控器用遥控器麦", "Keyboard -> Mac mic, Remote -> Remote mic")
        case .remoteOnly: return vm.t("仅遥控器近场收音 · 待机还原本机麦", "Remote mic only · Restores system mic on idle")
        case .dualMix: return vm.t("双麦合并：Mac 麦延迟 120ms 对齐遥控器", "Dual mix: Mac mic aligned +120ms")
        }
    }

    private func macChannelCard(scale: CGFloat, barHeight: CGFloat) -> some View {
        let isLive = vm.isMacEnabled && (vm.isRecording || vm.isTestSpeaking) && (vm.activeTriggerSource != .remote || vm.micPolicy == .dualMix || vm.micPolicy == .macOnly || !vm.driverInstalled)
        return VStack(alignment: .leading, spacing: 8 * scale) {
            HStack {
                HStack(spacing: 10 * scale) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9 * scale).fill(palette.insetBg).frame(width: 32 * scale, height: 32 * scale)
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 13.5 * scale, weight: .semibold))
                            .foregroundColor(palette.ink1)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.t("MacBook 麦克风", "MacBook Microphone"))
                            .font(VibeFont.title(14 * scale))
                            .foregroundColor(palette.ink1)
                        Text(vm.t("电脑内置 / AirPods · 开箱即用", "Built-in / AirPods · Ready"))
                            .font(VibeFont.caption(11.5 * scale))
                            .foregroundColor(palette.ink2)
                    }
                }
                Spacer()
                CeramicToggle(isOn: vm.isMacEnabled, tint: palette.macGreen, palette: palette) {
                    vm.toggleMacChannel()
                }
            }

            Spacer(minLength: 4)

            VStack(spacing: 7 * scale) {
                HStack {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(vm.isMacEnabled ? palette.macGreen : palette.ink3.opacity(0.45))
                            .frame(width: 7, height: 7)
                        Text(macStatusSubtitle)
                            .font(VibeFont.caption(11.5 * scale))
                            .foregroundColor(palette.ink2)
                    }
                    Spacer()
                    Text(vm.formatDb(vm.macLevelDb))
                        .font(VibeFont.mono(11.5 * scale))
                        .foregroundColor(palette.ink2)
                }

                MicroLevelMeterView(db: vm.macLevelDb, isRemoteStyle: false, palette: palette, barHeight: barHeight)
            }

            Spacer(minLength: 4)

            HStack {
                Text(vm.isMacEnabled
                    ? (vm.micPolicy == .dualMix ? vm.t("120ms 对齐参与合并", "120ms aligned mix") : vm.t("零延迟直通", "Zero latency"))
                    : vm.t("已静音", "Muted"))
                Spacer()
                Text(vm.t("仅录音时采集 · 不常亮橙灯", "Capture on demand · No constant dot"))
            }
            .font(VibeFont.caption(11 * scale))
            .foregroundColor(palette.ink3)
        }
        .padding(15 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.cardBg))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isLive ? palette.macGreen : palette.borderSoft, lineWidth: isLive ? 1.5 : 1)
        )
        .opacity(vm.isMacEnabled ? 1.0 : 0.72)
    }

    private func remoteChannelCard(scale: CGFloat, barHeight: CGFloat) -> some View {
        let isLive = vm.isRecording && vm.driverInstalled && (vm.activeTriggerSource == .remote || vm.micPolicy == .remoteOnly || vm.micPolicy == .dualMix)
        return VStack(alignment: .leading, spacing: 8 * scale) {
            HStack {
                HStack(spacing: 10 * scale) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9 * scale).fill(palette.insetBg).frame(width: 32 * scale, height: 32 * scale)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13.5 * scale, weight: .semibold))
                            .foregroundColor(palette.ink1)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(vm.t("遥控器麦克风", "Remote Microphone"))
                                .font(VibeFont.title(14 * scale))
                                .foregroundColor(palette.ink1)
                            // 明确常驻展示 G9N9N 硬件真实蓝牙电量胶囊（未连显示 --%，已连自动读 0x180F 电池百分比）
                            remoteBatteryBadge(scale: scale)
                        }
                        Text(vm.driverInstalled
                            ? vm.t("G9N9N 蓝牙语音 · 内置驱动已就绪", "G9N9N BLE Voice · Driver Ready")
                            : vm.t("G9N9N 蓝牙语音 · 需启用内置驱动", "G9N9N BLE Voice · Needs Driver"))
                            .font(VibeFont.caption(11.5 * scale))
                            .foregroundColor(palette.ink2)
                    }
                }
                Spacer()
                if vm.driverInstalled {
                    CeramicToggle(isOn: vm.isRemoteEnabled, tint: palette.brand, palette: palette) {
                        vm.toggleRemoteChannel()
                    }
                } else {
                    Button {
                        vm.onRequestInstallDriver?(.smartByTriggerSource)
                    } label: {
                        Text(vm.isDriverBusy ? vm.t("启用中…", "Enabling…") : vm.t("一键启用", "Enable"))
                            .font(VibeFont.label(12 * scale, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12 * scale)
                            .frame(height: 28 * scale)
                            .background(RoundedRectangle(cornerRadius: 8).fill(palette.brand))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isDriverBusy)
                }
            }

            Spacer(minLength: 4)

            VStack(spacing: 7 * scale) {
                HStack {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(vm.isRemoteEnabled ? palette.brand : palette.ink3.opacity(0.45))
                            .frame(width: 7, height: 7)
                        Text(!vm.driverInstalled
                            ? vm.t("未启用驱动（语音键触发不受影响）", "Driver off (voice key trigger still works)")
                            : (vm.isRemoteEnabled
                                ? (vm.micPolicy == .smartByTriggerSource ? vm.t("遥控器触发时启用", "Active on remote trigger") : vm.t("已开启 · 参与收音", "Enabled · Active"))
                                : vm.t("已暂停", "Paused")))
                            .font(VibeFont.caption(11.5 * scale))
                            .foregroundColor(palette.ink2)
                    }
                    Spacer()
                    Text(vm.formatDb(vm.remoteLevelDb))
                        .font(VibeFont.mono(11.5 * scale))
                        .foregroundColor(palette.ink2)
                }

                MicroLevelMeterView(db: vm.remoteLevelDb, isRemoteStyle: true, palette: palette, barHeight: barHeight)
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                if vm.driverInstalled {
                    // 3 档实时收音灵敏度切换胶囊（直接作用于 ADPCM 解码后的线性 DSP 增益）
                    HStack(spacing: 2) {
                        ForEach(RemoteMicGainPreset.allCases) { gain in
                            let active = vm.remoteGainPreset == gain
                            Button {
                                vm.selectRemoteGain(gain)
                            } label: {
                                Text("\(gain.title(lang: vm.language)) \(gain.dbLabel)")
                                    .font(VibeFont.label(10 * scale, weight: active ? .semibold : .medium))
                                    .foregroundColor(active ? palette.brand : palette.ink3)
                                    .padding(.horizontal, 6 * scale)
                                    .padding(.vertical, 2.5 * scale)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(active ? palette.brandSoft : Color.clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.insetBg))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.borderSoft, lineWidth: 0.8))
                } else {
                    Text(vm.t("点击「一键启用」自动安装，无需终端", "Click Enable to install automatically"))
                        .font(VibeFont.caption(11 * scale))
                        .foregroundColor(palette.ink3)
                }
                Spacer()
                Text("ATVV 16kHz")
                    .font(VibeFont.mono(10.5 * scale))
                    .foregroundColor(palette.ink3)
            }
        }
        .padding(15 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.cardBg))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isLive ? palette.brand : palette.borderSoft, lineWidth: isLive ? 1.5 : 1)
        )
        .opacity(vm.isRemoteEnabled ? 1.0 : 0.75)
    }

    /// 明确展示的硬件蓝牙电池状态胶囊（未连显示 --%，已连读取 0x180F/0x2A19 真实电量）
    private func remoteBatteryBadge(scale: CGFloat) -> some View {
        let connected = vm.bleConnected || vm.hidConnected
        let level = vm.remoteBatteryLevel
        let isLow = (level ?? 100) < 20
        let iconName: String = {
            guard let pct = level else { return "battery.0" }
            if pct >= 85 { return "battery.100" }
            if pct >= 55 { return "battery.75" }
            if pct >= 30 { return "battery.50" }
            return "battery.25"
        }()
        let text: String = {
            if let pct = level {
                return vm.t("电量 \(pct)%", "Bat \(pct)%")
            }
            if connected {
                return vm.t("电量读取中", "Bat …")
            }
            return vm.t("电量 --%", "Bat --%")
        }()
        let fg: Color = {
            if let _ = level { return isLow ? palette.amber : palette.macGreen }
            return palette.ink3
        }()
        let bg: Color = {
            if let _ = level { return isLow ? palette.amberSoft : palette.macGreenSoft }
            return palette.insetBg
        }()
        return HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 10.5 * scale, weight: .semibold))
            Text(text)
                .font(VibeFont.mono(10 * scale, weight: .semibold))
        }
        .foregroundColor(fg)
        .padding(.horizontal, 7 * scale)
        .padding(.vertical, 2.5 * scale)
        .background(Capsule().fill(bg))
        .overlay(Capsule().stroke(fg.opacity(level != nil ? 0.35 : 0.16), lineWidth: 0.8))
        .help(vm.t(
            "通过蓝牙标准电池服务 (0x180F) 读取 G9N9N 遥控器两节 7 号电池真实硬件电量；未连接时显示 --%",
            "Reads real G9N9N AAA battery level via BLE Battery Service (0x180F); shows --% while offline"
        ))
    }

    private func outputHubCard(scale: CGFloat, barHeight: CGFloat) -> some View {
        let topBarColor: Color = vm.doubaoRouteMismatch ? palette.amber : (vm.micPolicy == .remoteOnly ? palette.brand : palette.macGreen)
        return VStack(alignment: .leading, spacing: 10 * scale) {
            VStack(alignment: .leading, spacing: 10 * scale) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.t("语音输出通道", "Voice Output Bus"))
                            .font(VibeFont.title(15 * scale))
                            .foregroundColor(palette.ink1)
                        Text(vm.t("发送给 \(vm.voiceInputMethod.title(lang: .zh))", "Sending to \(vm.voiceInputMethod.title(lang: .en))"))
                            .font(VibeFont.caption(11.5 * scale))
                            .foregroundColor(palette.ink2)
                    }
                    Spacer()
                    Text(vm.formatDb(vm.outputLevelDb))
                        .font(VibeFont.mono(12 * scale))
                        .foregroundColor(palette.ink2)
                }

                // 定制输入法选择条（无原生 Picker）
                HStack {
                    Text(vm.t("目标输入法", "Target IME"))
                        .font(VibeFont.label(12 * scale, weight: .medium))
                        .foregroundColor(palette.ink2)
                    Spacer()
                    CustomSelectPill(text: vm.voiceInputMethod.title(lang: vm.language), isHighlighted: false, palette: palette, minWidth: 140 * scale) {
                        showImePopover.toggle()
                    }
                    .popover(isPresented: $showImePopover, arrowEdge: .bottom) {
                        IMEPopoverView(current: vm.voiceInputMethod, lang: vm.language, palette: palette) { selected in
                            vm.selectInputMethod(selected)
                            showImePopover = false
                        }
                    }
                }
                .padding(.horizontal, 11 * scale)
                .padding(.vertical, 8 * scale)
                .background(RoundedRectangle(cornerRadius: 10).fill(palette.insetBg))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.borderSoft, lineWidth: 1))
            }

            Spacer(minLength: 6)

            VStack(spacing: 7 * scale) {
                HStack {
                    let isLive = vm.isRecording || vm.isTestSpeaking
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isLive ? (vm.activeTriggerSource == .remote && vm.driverInstalled ? palette.brand : palette.macGreen) : palette.ink3.opacity(0.45))
                            .frame(width: 7, height: 7)
                        Text(localizedSessionStatusText)
                            .font(VibeFont.caption(11.5 * scale))
                            .foregroundColor(isLive ? palette.ink1 : palette.ink2)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(vm.micPolicy == .dualMix && vm.driverInstalled ? vm.t("120ms 对齐", "120ms sync") : "0ms")
                        .font(VibeFont.mono(11 * scale))
                        .foregroundColor(palette.ink2)
                }
                MicroLevelMeterView(db: vm.outputLevelDb, isRemoteStyle: vm.activeTriggerSource == .remote && vm.driverInstalled, palette: palette, barHeight: barHeight)
            }

            Spacer(minLength: 6)

            VStack(spacing: 10 * scale) {
                HStack {
                    let usesVirtual = vm.driverInstalled && !vm.isAllMicsClosed && vm.micPolicy.requiresDriver
                    HStack(spacing: 6) {
                        Circle().fill(vm.isAllMicsClosed ? palette.ink3.opacity(0.45) : (vm.micPolicy == .remoteOnly && vm.driverInstalled ? palette.brand : palette.macGreen)).frame(width: 7, height: 7)
                        Text(routeSummaryLabel)
                            .font(VibeFont.label(12 * scale, weight: .semibold))
                            .foregroundColor(palette.ink1)
                    }
                    Spacer()
                    Text(usesVirtual ? vm.t("按需切虚拟麦", "On-demand Mic") : vm.t("系统原物理麦", "Native Mac Mic"))
                        .font(VibeFont.mono(10.5 * scale))
                        .foregroundColor(palette.ink2)
                }
                .padding(.horizontal, 12 * scale)
                .padding(.vertical, 10 * scale)
                .background(RoundedRectangle(cornerRadius: 10).fill(palette.insetBg))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.borderSoft, lineWidth: 1))

                HStack(spacing: 8 * scale) {
                    Button {
                        vm.onTestSpeakRequested?()
                    } label: {
                        HStack(spacing: 6) {
                            if vm.isTestSpeaking {
                                Circle()
                                    .fill(palette.macGreen)
                                    .frame(width: 7, height: 7)
                            }
                            Text(vm.isTestSpeaking ? vm.t("停止试说测试", "Stop Test") : vm.t("触发试说测试", "Test Voice"))
                                .font(VibeFont.label(12 * scale, weight: .semibold))
                                .foregroundColor(vm.isTestSpeaking ? palette.macGreen : palette.ink1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 33 * scale)
                        .background(RoundedRectangle(cornerRadius: 8).fill(vm.isTestSpeaking ? palette.macGreenSoft : palette.cardBg))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(vm.isTestSpeaking ? palette.macGreen : palette.borderMed, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if vm.driverInstalled {
                        Button {
                            showUninstallConfirm = true
                        } label: {
                            Text(vm.t("卸载驱动", "Uninstall"))
                                .font(VibeFont.label(12 * scale, weight: .semibold))
                                .foregroundColor(palette.brand)
                                .padding(.horizontal, 12 * scale)
                                .frame(minHeight: 33 * scale)
                                .background(RoundedRectangle(cornerRadius: 8).fill(palette.brandSoft))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.brandBorder, lineWidth: 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.isDriverBusy)
                    }
                }
            }
        }
        .padding(16 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.cardBg))
        .overlay(
            VStack(spacing: 0) {
                topBarColor.frame(height: 2.5)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        )
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.borderSoft, lineWidth: 1))
    }

    private var localizedSessionStatusText: String {
        if vm.isTestSpeaking {
            return vm.t("试说测试中 · 正在收音", "Test Speaking · Listening")
        }
        if vm.language == .zh {
            return vm.sessionStatusText
        }
        if vm.sessionStatusText == "等待录音" {
            return "Idle · Ready"
        }
        if vm.sessionStatusText == "驱动未启用" {
            return "Driver not enabled"
        }
        if vm.isRecording {
            let sourceText = vm.activeTriggerSource == .remote ? "Remote Trigger" : "Keyboard Trigger"
            return "\(vm.voiceInputMethod.title(lang: .en)) · \(sourceText)"
        }
        return vm.sessionStatusText
    }

    private var routeSummaryLabel: String {
        if vm.isAllMicsClosed {
            return vm.t("双麦已暂停（未接管）", "Mics Muted (Untouched)")
        }
        if !vm.driverInstalled {
            return vm.t("电脑麦直通", "Mac Mic Direct")
        }
        switch vm.micPolicy {
        case .macOnly: return vm.t("电脑麦直通（未接管）", "Mac Mic Direct")
        case .smartByTriggerSource: return vm.t("智能按源自动选通", "Smart Auto Switch")
        case .remoteOnly: return vm.t("仅遥控器近场麦", "Remote Mic Only")
        case .dualMix: return vm.t("两路已对齐合并", "Dual Mic Aligned")
        }
    }

    private var macStatusSubtitle: String {
        if vm.isAllMicsClosed {
            return vm.t("已关闭 · 系统麦已还原", "Muted · System mic untouched")
        }
        if !vm.driverInstalled {
            return vm.t("已开启 · 录音时实时亮柱", "Enabled · Live meter on talk")
        }
        if !vm.isMacEnabled {
            return vm.t("已关闭（仅遥控器近场收音）", "Off (Remote mic only)")
        }
        return vm.micPolicy == .smartByTriggerSource
            ? vm.t("键盘触发时启用", "Active on keyboard trigger")
            : vm.t("已开启 · 参与收音", "Enabled · Active")
    }

    /// 体检卡语义视觉等级（让「正常 / 待处理 / 可操作」一目了然）
    private enum HealthTone {
        case ok        // 翠绿就绪
        case attention // 琥珀待连接/待授权
        case action    // 朱砂一键操作
    }

    private func healthSection(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            HStack {
                Text(vm.t("系统状态与权限自检（点击任意项可直达设置或处理）", "System Status & Permissions (Click any card to configure)"))
                    .font(VibeFont.label(12 * scale, weight: .medium))
                    .foregroundColor(palette.ink2)
                Spacer()
                Text(vm.t("异常退出自动还原系统默认麦克风", "Auto-restores system mic on crash"))
                    .font(VibeFont.caption(11 * scale))
                    .foregroundColor(palette.ink3)
            }

            let remoteReady = vm.bleConnected || vm.hidConnected
            let inputAndBtReady = vm.permissions.inputMonitoringGranted && vm.permissions.bluetoothGranted

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10 * scale), count: 3), spacing: 10 * scale) {
                healthTile(
                    title: vm.t("目标语音工具", "Voice Input Tool"),
                    value: vm.voiceInputMethod.title(lang: vm.language),
                    badge: vm.doubaoRouteMismatch
                        ? vm.t("请检查选麦 →", "Check Mic →")
                        : "\(vm.triggerShortcut.displayShortLabel(lang: vm.language)) · \(vm.language == .en ? (vm.triggerMode == .hold ? "Hold" : "Tap") : vm.triggerMode.title)",
                    tone: vm.doubaoRouteMismatch ? .attention : .ok,
                    scale: scale
                ) {
                    vm.selectPage(.mapping)
                }

                healthTile(
                    title: vm.t("遥控器声卡", "Remote Audio Driver"),
                    value: vm.driverInstalled
                        ? vm.t("G9NVibe Mic 已启用", "Driver Ready")
                        : vm.t("未启用（仅电脑麦）", "Off (Mac Mic Only)"),
                    badge: vm.isDriverBusy
                        ? vm.t("处理中…", "Working…")
                        : (vm.driverInstalled
                            ? vm.t("✓ 已启用", "✓ Active")
                            : vm.t("一键启用 →", "Enable →")),
                    tone: vm.driverInstalled ? .ok : .action,
                    scale: scale
                ) {
                    guard !vm.isDriverBusy else { return }
                    if vm.driverInstalled {
                        showUninstallConfirm = true
                    } else {
                        vm.onRequestInstallDriver?(.smartByTriggerSource)
                    }
                }

                let lowBattery = (vm.remoteBatteryLevel ?? 100) < 20
                let remoteBadgeText: String = {
                    if !remoteReady { return vm.t("去蓝牙连接 →", "Bluetooth →") }
                    if let pct = vm.remoteBatteryLevel {
                        return vm.t("✓ 电量 \(pct)%", "✓ \(pct)%")
                    }
                    return vm.t("✓ 已连接", "✓ Paired")
                }()
                healthTile(
                    title: vm.t("G9N9N 遥控器", "G9N9N Remote"),
                    value: connectionSummary,
                    badge: remoteBadgeText,
                    tone: (remoteReady && !lowBattery) ? .ok : .attention,
                    scale: scale
                ) {
                    vm.openSystemPrivacyPane("Privacy_Bluetooth")
                }

                healthTile(
                    title: vm.t("麦克风权限", "Microphone"),
                    value: vm.permissions.microphoneGranted ? vm.t("已授权", "Granted") : vm.t("未授权", "Missing"),
                    badge: vm.permissions.microphoneGranted ? vm.t("✓ 正常", "✓ OK") : vm.t("去授权 →", "Grant →"),
                    tone: vm.permissions.microphoneGranted ? .ok : .attention,
                    scale: scale
                ) {
                    vm.requestMicrophonePermissionIfNeeded()
                }

                healthTile(
                    title: vm.t("辅助功能权限", "Accessibility"),
                    value: vm.permissions.accessibilityGranted ? vm.t("已授权", "Granted") : vm.t("未授权", "Missing"),
                    badge: vm.permissions.accessibilityGranted ? vm.t("✓ 正常", "✓ OK") : vm.t("去授权 →", "Grant →"),
                    tone: vm.permissions.accessibilityGranted ? .ok : .attention,
                    scale: scale
                ) {
                    vm.requestAccessibilityPermission()
                }

                healthTile(
                    title: vm.t("输入监控与蓝牙", "Input & Bluetooth"),
                    value: inputAndBtReady ? vm.t("已授权", "Granted") : vm.t("需补全", "Action Needed"),
                    badge: inputAndBtReady ? vm.t("✓ 正常", "✓ OK") : vm.t("去设置 →", "Settings →"),
                    tone: inputAndBtReady ? .ok : .attention,
                    scale: scale
                ) {
                    if !vm.permissions.inputMonitoringGranted {
                        vm.requestInputMonitoringPermission()
                    } else {
                        vm.openSystemPrivacyPane("Privacy_Bluetooth")
                    }
                }
            }
        }
    }

    private var connectionSummary: String {
        switch (vm.bleConnected, vm.hidConnected) {
        case (true, true): return vm.t("BLE · HID 已就绪", "BLE & HID Ready")
        case (true, false): return vm.t("BLE 语音已就绪", "BLE Voice Ready")
        case (false, true): return vm.t("HID 按键已就绪", "HID Keys Ready")
        case (false, false): return vm.t("等待蓝牙连接…", "Waiting Bluetooth…")
        }
    }

    private func healthTile(
        title: String,
        value: String,
        badge: String,
        tone: HealthTone,
        scale: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        let accent: Color
        let badgeBg: Color
        let cardBg: Color
        let borderColor: Color
        switch tone {
        case .ok:
            accent = palette.macGreen
            badgeBg = palette.macGreenSoft
            cardBg = palette.cardBg
            borderColor = palette.macGreen.opacity(0.28)
        case .attention:
            accent = palette.amber
            badgeBg = palette.amberSoft
            cardBg = palette.amberSoft.opacity(0.62)
            borderColor = palette.amber.opacity(0.50)
        case .action:
            accent = palette.brand
            badgeBg = palette.brandSoft
            cardBg = palette.cardBg
            borderColor = palette.brandBorder
        }

        return Button(action: action) {
            HStack(spacing: 0) {
                // 左侧 3.5pt 语义高亮状态竖条，扫一眼立刻分辨健康 / 待处理 / 可启用
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent)
                    .frame(width: 3.5)
                    .padding(.vertical, 8 * scale)
                    .padding(.leading, 6)

                VStack(alignment: .leading, spacing: 6 * scale) {
                    HStack {
                        Text(title)
                            .font(VibeFont.label(11.5 * scale, weight: .medium))
                            .foregroundColor(palette.ink2)
                        Spacer()
                        Circle()
                            .fill(accent)
                            .frame(width: 7, height: 7)
                    }
                    HStack(alignment: .center, spacing: 6) {
                        Text(value)
                            .font(VibeFont.title(12.5 * scale))
                            .foregroundColor(palette.ink1)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(badge)
                            .font(VibeFont.label(10.5 * scale, weight: .semibold))
                            .foregroundColor(accent)
                            .padding(.horizontal, 7 * scale)
                            .padding(.vertical, 2.5 * scale)
                            .background(Capsule().fill(badgeBg))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10 * scale)
                .padding(.vertical, 10 * scale)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(cardBg))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(borderColor, lineWidth: 1.1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
