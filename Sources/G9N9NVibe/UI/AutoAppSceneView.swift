import AppKit
import SwiftUI

/// 页面 4：自动场景（独立 Tab 专门配置「随前台应用自动切换预设」，支持自由添加当前运行的应用规则）
struct AutoAppSceneView: View {
    @ObservedObject var vm: AppViewModel
    @ObservedObject var store: RemoteMappingStore
    let palette: VibePalette

    @State private var showRunningAppsPopover = false

    private let builtInCodingApps: [(name: String, badge: String)] = [
        ("Cursor", "IDE"),
        ("VS Code", "IDE"),
        ("Antigravity", "AI"),
        ("Xcode", "IDE"),
        ("JetBrains", "IDE"),
        ("Windsurf", "AI"),
        ("Zed", "IDE"),
        ("Trae", "AI"),
        ("Terminal", "CLI"),
        ("iTerm2", "CLI"),
        ("Warp", "CLI"),
        ("Ghostty", "CLI"),
    ]

    private let officeExamples: [(zh: String, en: String)] = [
        ("Chrome / Safari / Arc 浏览器", "Chrome / Safari / Arc"),
        ("微信 / 飞书 / 钉钉 / Slack", "WeChat / Lark / Slack"),
        ("Keynote / PowerPoint 演示", "Keynote / PowerPoint"),
        ("音乐 / Spotify / IINA / B站", "Music / Spotify / IINA"),
        ("Notion / 备忘录 / 飞书文档", "Notion / Notes / Docs"),
    ]

    var body: some View {
        VStack(spacing: 14) {
            // 顶部总开关大卡片
            masterToggleCard

            // 主体左右舒展双栏规则卡片
            HStack(spacing: 14) {
                vibeCodingRuleCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                officeRuleCard
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(store.autoSwitchByApp ? 1.0 : 0.62)
        }
    }

    private var masterToggleCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11)
                    .fill(store.autoSwitchByApp ? palette.macGreenSoft : palette.insetBg)
                    .frame(width: 42, height: 42)
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(store.autoSwitchByApp ? palette.macGreen : palette.ink2)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(vm.t("随前台应用自动切换预设", "Auto-Switch Preset by Active App"))
                        .font(VibeFont.title(15))
                        .foregroundColor(palette.ink1)
                    Text(store.autoSwitchByApp
                        ? vm.t("运行中 · 当前：\(store.activePreset.title(lang: .zh))", "Active · \(store.activePreset.title(lang: .en))")
                        : vm.t("未开启", "Off"))
                        .font(VibeFont.label(11, weight: .semibold))
                        .foregroundColor(store.autoSwitchByApp ? palette.macGreen : palette.ink3)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(store.autoSwitchByApp ? palette.macGreenSoft : palette.insetBg))
                }
                Text(vm.t(
                    "基于 macOS 原生前台切换事件（零轮询零耗电）；切回 G9NVibe 窗口时自动暂停切换，方便你安心改键。",
                    "Powered by native macOS workspace notifications (zero polling). Pauses while G9NVibe is focused."
                ))
                .font(VibeFont.caption(11.5))
                .foregroundColor(palette.ink2)
            }

            Spacer(minLength: 10)

            CeramicToggle(isOn: store.autoSwitchByApp, tint: palette.macGreen, palette: palette) {
                let next = !store.autoSwitchByApp
                store.setAutoSwitchByApp(next)
                vm.showToast(
                    next
                        ? vm.t("✓ 已开启随前台应用自动切换预设", "✓ Auto-switch preset enabled")
                        : vm.t("已关闭自动切换预设", "Auto-switch preset disabled"),
                    positive: next
                )
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.cardBg))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(store.autoSwitchByApp ? palette.macGreen.opacity(0.42) : palette.borderSoft, lineWidth: 1.1)
        )
    }

    private var vibeCodingRuleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(palette.brand).frame(width: 7.5, height: 7.5)
                        Text(vm.t("编程 / AI 工具 → Vibe Coding 预设", "IDEs & Terminals → Vibe Coding"))
                            .font(VibeFont.title(14))
                            .foregroundColor(palette.ink1)
                    }
                    Text(vm.t("切换到以下任意开发工具时，自动启用你的 Vibe Coding 键位", "Automatically activates your Vibe Coding key map in these apps"))
                        .font(VibeFont.caption(11.5))
                        .foregroundColor(palette.ink2)
                }
                Spacer()
            }

            // 内置支持的编程/终端应用网格
            VStack(alignment: .leading, spacing: 7) {
                Text(vm.t("内置识别列表", "Built-in Recognition"))
                    .font(VibeFont.label(11.5, weight: .semibold))
                    .foregroundColor(palette.ink3)

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)],
                    spacing: 7
                ) {
                    ForEach(builtInCodingApps, id: \.name) { item in
                        HStack(spacing: 5) {
                            Text(item.name)
                                .font(VibeFont.label(11.5, weight: .medium))
                                .foregroundColor(palette.ink1)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(item.badge)
                                .font(VibeFont.mono(9.5, weight: .semibold))
                                .foregroundColor(palette.ink3)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(palette.insetBg))
                    }
                }
            }

            Divider().background(palette.borderSoft)

            // 用户自定义添加的编程应用列表
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(vm.t("自定义添加的应用", "Custom Coding Apps"))
                        .font(VibeFont.label(11.5, weight: .semibold))
                        .foregroundColor(palette.ink3)
                    Spacer()
                    Button {
                        showRunningAppsPopover.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 10.5, weight: .bold))
                            Text(vm.t("添加当前运行应用", "Add Running App"))
                                .font(VibeFont.label(11.5, weight: .semibold))
                        }
                        .foregroundColor(palette.brand)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(palette.brandSoft))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.brandBorder, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showRunningAppsPopover, arrowEdge: .bottom) {
                        RunningAppsPickerPopover(
                            existingBundleIDs: store.customCodingBundleIDSet,
                            lang: vm.language,
                            palette: palette
                        ) { bundleID, name in
                            store.addCustomCodingApp(bundleID: bundleID, appName: name)
                            showRunningAppsPopover = false
                            vm.showToast(vm.t("✓ 已将「\(name)」加入 Vibe Coding 自动场景", "✓ Added \(name) to Vibe Coding rules"))
                        }
                    }
                }

                if store.customCodingApps.isEmpty {
                    Text(vm.t("暂无自定义应用；如果你使用其他编辑器或终端，点右上角一键添加即可。", "No custom apps yet. Click Add Running App to include any other IDE or terminal."))
                        .font(VibeFont.caption(11.5))
                        .foregroundColor(palette.ink3)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(store.customCodingApps) { rule in
                                HStack {
                                    Text(rule.appName)
                                        .font(VibeFont.label(12, weight: .semibold))
                                        .foregroundColor(palette.ink1)
                                    Text(rule.bundleID)
                                        .font(VibeFont.mono(10))
                                        .foregroundColor(palette.ink3)
                                        .lineLimit(1)
                                    Spacer()
                                    Button {
                                        store.removeCustomCodingApp(bundleID: rule.bundleID)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(palette.ink3)
                                            .frame(width: 22, height: 22)
                                            .background(Circle().fill(palette.insetBg))
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(palette.insetBg.opacity(0.65)))
                            }
                        }
                    }
                    .frame(maxHeight: 110)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.borderSoft, lineWidth: 1))
    }

    private var officeRuleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(palette.macGreen).frame(width: 7.5, height: 7.5)
                    Text(vm.t("其他应用 → 日常办公 / 媒体预设", "Other Apps → Office / Media"))
                        .font(VibeFont.title(14))
                        .foregroundColor(palette.ink1)
                }
                Text(vm.t("离开编程工具切到浏览器、聊天或影音应用时，自动恢复媒体音量与办公键位", "Automatically restores media volume & office keys outside coding apps"))
                    .font(VibeFont.caption(11.5))
                    .foregroundColor(palette.ink2)
            }

            VStack(spacing: 8) {
                ForEach(officeExamples, id: \.zh) { item in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(palette.macGreen.opacity(0.75))
                            .frame(width: 5.5, height: 5.5)
                        Text(vm.language == .en ? item.en : item.zh)
                            .font(VibeFont.label(12, weight: .medium))
                            .foregroundColor(palette.ink1)
                        Spacer()
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(palette.insetBg))
                }
            }

            Spacer(minLength: 6)

            // 独立档案与实时状态卡片
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 12))
                        .foregroundColor(palette.macGreen)
                    Text(vm.t("两套键位档案完全独立保存", "Two Independent Key Profiles"))
                        .font(VibeFont.label(12, weight: .semibold))
                        .foregroundColor(palette.ink1)
                }
                Text(vm.t(
                    "你在「Vibe Coding」与「日常办公」里各自修改的短按、长按与自录快捷键均独立保存，自动来回切换绝不互相覆盖。",
                    "Your tap, hold, and custom bindings for Vibe Coding and Office are stored independently and never overwrite each other."
                ))
                .font(VibeFont.caption(11))
                .foregroundColor(palette.ink2)

                if let appName = vm.autoSwitchedAppName, store.autoSwitchByApp {
                    HStack(spacing: 5) {
                        Circle().fill(palette.macGreen).frame(width: 6, height: 6)
                        Text(vm.t("最近自动响应应用：\(appName)", "Last matched app: \(appName)"))
                            .font(VibeFont.mono(10.5, weight: .medium))
                            .foregroundColor(palette.macGreen)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.macGreenSoft.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.macGreen.opacity(0.28), lineWidth: 1))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.borderSoft, lineWidth: 1))
    }
}

/// 从当前电脑正在运行的常规应用中一键选择添加到「Vibe Coding 自动场景」
private struct RunningAppsPickerPopover: View {
    let existingBundleIDs: Set<String>
    let lang: AppLanguage
    let palette: VibePalette
    let onPick: (String, String) -> Void

    private var runningApps: [(bundleID: String, name: String)] {
        var seen = Set<String>()
        var result: [(String, String)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bid = app.bundleIdentifier,
                  !bid.isEmpty,
                  bid.lowercased() != AppStorage.bundleIdentifier.lowercased(),
                  let name = app.localizedName,
                  !seen.contains(bid.lowercased()) else {
                continue
            }
            seen.insert(bid.lowercased())
            result.append((bid, name))
        }
        return result.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lang == .en ? "Add a Running App to Vibe Coding" : "选择要加入「Vibe Coding」的运行中应用")
                .font(VibeFont.label(11.5, weight: .semibold))
                .foregroundColor(palette.ink2)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(runningApps, id: \.bundleID) { item in
                        let added = existingBundleIDs.contains(item.bundleID.lowercased())
                        Button {
                            if !added {
                                onPick(item.bundleID, item.name)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name)
                                        .font(VibeFont.label(12, weight: .semibold))
                                        .foregroundColor(added ? palette.ink3 : palette.ink1)
                                    Text(item.bundleID)
                                        .font(VibeFont.mono(9.5))
                                        .foregroundColor(palette.ink3)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if added {
                                    Text(lang == .en ? "Added" : "已添加")
                                        .font(VibeFont.label(10.5, weight: .semibold))
                                        .foregroundColor(palette.macGreen)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(added ? palette.insetBg : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(added)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(12)
        .frame(width: 288)
        .background(palette.cardBg)
    }
}
