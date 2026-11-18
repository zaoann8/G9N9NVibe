import AppKit
import SwiftUI

/// 原生软件更新弹窗：展示版本对比、更新说明、实时下载进度、原子覆盖升级与手动下载兜底
struct UpdateSheetView: View {
    @ObservedObject var vm: AppViewModel
    let palette: VibePalette

    private var currentVersion: String { AppStorage.appVersionString }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 顶部品牌与版本标识
            HStack(spacing: 12) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.t("G9NVibe 软件更新", "G9NVibe Software Update"))
                        .font(VibeFont.brand(16))
                        .foregroundColor(palette.ink1)
                    Text(vm.t("当前版本 v\(currentVersion) · 覆盖更新自动保留全部系统权限", "Current v\(currentVersion) · Preserves all macOS permissions"))
                        .font(VibeFont.caption(11.5))
                        .foregroundColor(palette.ink2)
                }
                Spacer()
                Button {
                    if !vm.updateState.isBusy {
                        vm.showUpdateSheet = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(palette.ink3)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(palette.insetBg))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(vm.updateState.isBusy)
            }

            Divider().background(palette.borderSoft)

            // 动态主体内容
            contentSection

            // 底部动作栏
            footerActions
        }
        .padding(20)
        .frame(width: 468)
        .background(palette.windowBg)
    }

    @ViewBuilder
    private var contentSection: some View {
        switch vm.updateState {
        case .idle, .checking:
            HStack(spacing: 10) {
                ProgressView().scaleEffect(0.75)
                Text(vm.t("正在连接 GitHub Releases 检查最新版本…", "Checking GitHub Releases for updates…"))
                    .font(VibeFont.label(13))
                    .foregroundColor(palette.ink1)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(palette.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.borderSoft, lineWidth: 1))

        case .upToDate(let ver):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(palette.macGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.t("当前已是最新版本 (v\(ver))", "You're up to date (v\(ver))"))
                        .font(VibeFont.title(13.5))
                        .foregroundColor(palette.ink1)
                    Text(vm.t("无需手动操作，每天启动时会自动静默检查一次新版本。", "G9NVibe checks silently once per day on launch."))
                        .font(VibeFont.caption(11.5))
                        .foregroundColor(palette.ink2)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(palette.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.macGreen.opacity(0.32), lineWidth: 1))

        case .notConfigured:
            VStack(alignment: .leading, spacing: 6) {
                Text(vm.t("本地开发构建尚未绑定 GitHub 仓库", "GitHub Repository Not Bound Yet"))
                    .font(VibeFont.title(13.5))
                    .foregroundColor(palette.ink1)
                Text(vm.t(
                    "通过 GitHub Actions 打包发布的 DMG 会自动写入你的仓库地址，届时所有用户均可一键在线检查、校验 SHA-256 并自动覆盖更新。",
                    "DMG builds packaged by GitHub Actions automatically embed your repository for one-click in-app updates."
                ))
                .font(VibeFont.caption(12))
                .foregroundColor(palette.ink2)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(palette.cardBg))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.borderSoft, lineWidth: 1))

        case .failed(let msg):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(palette.amber)
                VStack(alignment: .leading, spacing: 3) {
                    Text(vm.t("更新过程遇到问题", "Update Notice"))
                        .font(VibeFont.title(13.5))
                        .foregroundColor(palette.ink1)
                    Text(msg)
                        .font(VibeFont.caption(12))
                        .foregroundColor(palette.ink2)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(palette.amberSoft.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.amber.opacity(0.4), lineWidth: 1))

        case .available(let info):
            releaseInfoCard(info, statusLine: nil, progress: nil)

        case .downloading(let info, let progress):
            let pct = Int((progress * 100).rounded())
            releaseInfoCard(info, statusLine: vm.t("正在下载新版本安装包… \(pct)%", "Downloading update… \(pct)%"), progress: progress)

        case .verifying(let info):
            releaseInfoCard(info, statusLine: vm.t("正在校验 SHA-256 哈希与代码签名完整性…", "Verifying SHA-256 & code signature…"), progress: nil)

        case .installing(let info):
            releaseInfoCard(info, statusLine: vm.t("校验通过，正在原子覆盖安装并自动重启…", "Verified. Installing atomically and relaunching…"), progress: 1.0)
        }
    }

    @ViewBuilder
    private func releaseInfoCard(_ info: ReleaseUpdateInfo, statusLine: String?, progress: Double?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("v\(currentVersion)  →  \(info.tagName)")
                    .font(VibeFont.mono(13, weight: .bold))
                    .foregroundColor(palette.brand)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(palette.brandSoft))
                Spacer()
                if let size = info.dmgFileSize {
                    let mb = String(format: "%.1f MB", Double(size) / (1024.0 * 1024.0))
                    Text(mb)
                        .font(VibeFont.mono(11))
                        .foregroundColor(palette.ink3)
                }
            }

            if !info.releaseNotes.isEmpty {
                ScrollView {
                    Text(info.releaseNotes)
                        .font(VibeFont.caption(12))
                        .foregroundColor(palette.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 136)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.insetBg))
            }

            if let statusLine {
                VStack(alignment: .leading, spacing: 6) {
                    Text(statusLine)
                        .font(VibeFont.label(12, weight: .semibold))
                        .foregroundColor(palette.ink1)
                    if let progress {
                        ProgressView(value: progress)
                            .tint(palette.brand)
                    } else {
                        ProgressView()
                            .scaleEffect(0.75)
                    }
                }
                .padding(.top, 2)
            } else {
                Text(vm.t(
                    "将自动下载 DMG、校验 SHA-256、安全还原系统麦后原子覆盖安装（失败自动回滚旧版）并自动重启。",
                    "Downloads DMG, verifies SHA-256, atomically replaces the app (auto-rollback on failure), and relaunches."
                ))
                .font(VibeFont.caption(11))
                .foregroundColor(palette.ink3)
            }
        }
        .padding(15)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.borderSoft, lineWidth: 1))
    }

    @ViewBuilder
    private var footerActions: some View {
        HStack(spacing: 10) {
            switch vm.updateState {
            case .available(let info):
                Button {
                    NSWorkspace.shared.open(info.releasePageURL)
                } label: {
                    Text(vm.t("打开 GitHub 下载", "Open GitHub"))
                        .font(VibeFont.label(12, weight: .semibold))
                        .foregroundColor(palette.ink2)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(palette.insetBg))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    vm.showUpdateSheet = false
                } label: {
                    Text(vm.t("稍后再说", "Later"))
                        .font(VibeFont.label(12, weight: .semibold))
                        .foregroundColor(palette.ink2)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(palette.insetBg))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    vm.startAutomaticUpdate(info)
                } label: {
                    Text(vm.t("立即下载并覆盖更新", "Download & Install"))
                        .font(VibeFont.label(12.5, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(palette.brand))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

            case .downloading:
                Spacer()
                Button {
                    vm.cancelAutomaticUpdate()
                } label: {
                    Text(vm.t("取消下载", "Cancel"))
                        .font(VibeFont.label(12, weight: .semibold))
                        .foregroundColor(palette.brand)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(palette.brandSoft))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

            case .verifying, .installing:
                Spacer()
                Text(vm.t("请稍候，切勿强制结束程序…", "Please wait…"))
                    .font(VibeFont.caption(11.5))
                    .foregroundColor(palette.ink3)

            default:
                Button {
                    vm.checkUpdatesManually()
                } label: {
                    Text(vm.t("重新检查", "Check Again"))
                        .font(VibeFont.label(12, weight: .semibold))
                        .foregroundColor(palette.ink1)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(palette.insetBg))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(vm.updateState == .checking)

                Spacer()

                Button {
                    vm.showUpdateSheet = false
                } label: {
                    Text(vm.t("关闭", "Close"))
                        .font(VibeFont.label(12, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(palette.ink1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
