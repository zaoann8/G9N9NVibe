import AppKit
import SwiftUI

/// 极简高呼吸感首次安装互动引导弹窗（告别密密麻麻文字墙，3 行直觉交互一步到位）
struct OnboardingView: View {
    @ObservedObject var vm: AppViewModel
    let palette: VibePalette

    var body: some View {
        VStack(spacing: 18) {
            // 极简品牌头图
            VStack(spacing: 8) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 58, height: 58)
                }
                Text(vm.t("欢迎使用 G9NVibe", "Welcome to G9NVibe"))
                    .font(VibeFont.brand(19))
                    .foregroundColor(palette.ink1)
            }

            // 3 行清爽互动配置条（每步仅 1 行短标题 + 直接操作）
            VStack(spacing: 10) {
                // 1. 蓝牙配对
                rowCard(
                    index: "1",
                    done: vm.bleConnected || vm.hidConnected,
                    title: vm.t("长按遥控器「返回 + Home」3 秒配对蓝牙", "Hold Back + Home 3s to pair via Bluetooth")
                ) {
                    Button {
                        vm.openSystemPrivacyPane("Privacy_Bluetooth")
                    } label: {
                        Text(vm.bleConnected || vm.hidConnected
                            ? vm.t("已连接 ✓", "Paired ✓")
                            : vm.t("蓝牙设置 →", "Bluetooth →"))
                            .font(VibeFont.label(11.5, weight: .semibold))
                            .foregroundColor(vm.bleConnected || vm.hidConnected ? palette.macGreen : palette.ink1)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(vm.bleConnected || vm.hidConnected ? palette.macGreenSoft : palette.insetBg))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.borderSoft, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // 2. 选择语音工具
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        stepBadge("2", done: true)
                        Text(vm.t("选择你的语音输入工具", "Pick your voice input tool"))
                            .font(VibeFont.title(13))
                            .foregroundColor(palette.ink1)
                    }
                    HStack(spacing: 8) {
                        ForEach(VoiceInputMethod.allCases) { item in
                            let selected = vm.voiceInputMethod == item
                            Button {
                                vm.selectInputMethod(item)
                            } label: {
                                Text(item.title(lang: vm.language))
                                    .font(VibeFont.label(11.5, weight: .semibold))
                                    .foregroundColor(selected ? palette.brand : palette.ink2)
                                    .frame(maxWidth: .infinity, minHeight: 28)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(selected ? palette.brandSoft : palette.insetBg))
                                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? palette.brandBorder : palette.borderSoft, lineWidth: 1))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(13)
                .background(RoundedRectangle(cornerRadius: 12).fill(palette.cardBg))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.borderSoft, lineWidth: 1))

                // 3. 权限核验
                let permOk = vm.permissions.microphoneGranted && vm.permissions.accessibilityGranted && vm.permissions.inputMonitoringGranted
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        stepBadge("3", done: permOk)
                        Text(vm.t("核验系统权限", "Check macOS permissions"))
                            .font(VibeFont.title(13))
                            .foregroundColor(palette.ink1)
                    }
                    HStack(spacing: 8) {
                        permChip(vm.t("麦克风", "Mic"), ok: vm.permissions.microphoneGranted) {
                            vm.requestMicrophonePermissionIfNeeded()
                        }
                        permChip(vm.t("辅助功能", "Accessibility"), ok: vm.permissions.accessibilityGranted) {
                            vm.requestAccessibilityPermission()
                        }
                        permChip(vm.t("输入监控", "Input Mon."), ok: vm.permissions.inputMonitoringGranted) {
                            vm.requestInputMonitoringPermission()
                        }
                    }
                }
                .padding(13)
                .background(RoundedRectangle(cornerRadius: 12).fill(palette.cardBg))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.borderSoft, lineWidth: 1))
            }

            // 底部简洁操作栏
            HStack(spacing: 10) {
                Button {
                    vm.toggleLaunchAtLogin()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: vm.launchAtLogin ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13.5))
                            .foregroundColor(vm.launchAtLogin ? palette.macGreen : palette.ink3)
                        Text(vm.t("开机自启动", "Launch at Login"))
                            .font(VibeFont.label(12))
                            .foregroundColor(palette.ink2)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    vm.toggleLanguage()
                } label: {
                    Text(vm.language == .zh ? "EN" : "中文")
                        .font(VibeFont.mono(11, weight: .semibold))
                        .foregroundColor(palette.ink2)
                        .padding(.horizontal, 11)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(palette.insetBg))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    vm.completeOnboarding()
                } label: {
                    Text(vm.t("开始使用", "Get Started"))
                        .font(VibeFont.label(13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(palette.brand))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(22)
        .frame(width: 472)
        .background(palette.windowBg)
    }

    private func stepBadge(_ text: String, done: Bool) -> some View {
        Text(done ? "✓" : text)
            .font(VibeFont.mono(10.5, weight: .bold))
            .foregroundColor(done ? palette.macGreen : palette.brand)
            .frame(width: 20, height: 20)
            .background(Circle().fill(done ? palette.macGreenSoft : palette.brandSoft))
    }

    private func rowCard<Trailing: View>(index: String, done: Bool, title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            stepBadge(index, done: done)
            Text(title)
                .font(VibeFont.title(13))
                .foregroundColor(palette.ink1)
                .lineLimit(1)
            Spacer(minLength: 6)
            trailing()
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.borderSoft, lineWidth: 1))
    }

    private func permChip(_ title: String, ok: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(ok ? palette.macGreen : palette.amber)
                    .frame(width: 6, height: 6)
                Text(ok ? "\(title) ✓" : "\(title) →")
                    .font(VibeFont.label(11.5, weight: .semibold))
            }
            .foregroundColor(ok ? palette.macGreen : palette.amber)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(ok ? palette.macGreenSoft : palette.amberSoft))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke((ok ? palette.macGreen : palette.amber).opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
