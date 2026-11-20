#if DEBUG
import CoreGraphics
import Foundation

/// 自动化状态机、智能随动全真值矩阵与魔鬼边界场景自测套件（16 项）
/// 运行方式：.build/debug/G9N9NVibe --voice-session-self-test
enum VoiceSessionSelfTest {
    private final class MockAudioState: AudioStateProviding {
        var onSnapshotChanged: ((AudioStateMonitor.Snapshot) -> Void)?
        var canObserveRecording: Bool
        var current: AudioStateMonitor.Snapshot

        init(observable: Bool = true, initialState: AudioStateMonitor.State = .inactive) {
            canObserveRecording = observable
            current = AudioStateMonitor.Snapshot(
                state: initialState,
                pid: 1001,
                inputDeviceNames: [AppStorage.virtualDriverDeviceName],
                captureObservable: observable
            )
        }

        func start() {}
        func stop() {}
        func snapshotNow() -> AudioStateMonitor.Snapshot { current }

        func emit(state: AudioStateMonitor.State) {
            current = AudioStateMonitor.Snapshot(
                state: state,
                pid: 1001,
                inputDeviceNames: [AppStorage.virtualDriverDeviceName],
                captureObservable: canObserveRecording
            )
            onSnapshotChanged?(current)
        }
    }

    private static var passedCount = 0

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("❌ 自测失败: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func run(_ name: String, _ block: () -> Void) {
        block()
        passedCount += 1
        print("  ✓ [\(passedCount)] \(name)")
    }

    static func runAll() {
        passedCount = 0
        run("全 48 种路由策略 × 触发源 × 驱动/静音真值矩阵校验", testRoutingTruthTable48Cases)
        run("智能随动核心不变式：键盘与遥控器严格互斥零回声", testSmartAutoSwitchStrictMutualExclusion)
        run("智能随动连续交替：键盘说一句 -> 遥控器说一句 -> 键盘再说一句", testSmartAlternatingKeyboardAndRemote)
        run("遥控器长按对讲（含防卡键释放）", testRemoteHoldToTalk)
        run("遥控器短按开关（含短按后静默续麦）", testRemoteShortTapToggleAndRenew)
        run("遥控器单流超时（非物理松手）自动续麦保活", testRemoteStreamTimeoutAutoRenew)
        run("魔鬼 Case：遥控器说话中蓝牙突然断连（0xFB）立即收敛防卡键", testRemoteDisconnectDuringActiveSession)
        run("魔鬼 Case：键盘录音期间误收到遥控器迟到非物理唤醒包不串麦", testLateRemotePacketCannotHijackKeyboardSession)
        run("魔鬼 Case：会话关闭途中收到迟到 AUDIO_START 必须立刻拒绝并关麦", testLateRemoteStartDuringClosingRejected)
        run("魔鬼 Case：键盘短按开麦中，按遥控器短按关闭会话", testCrossDeviceStopFromRemote)
        run("魔鬼 Case：遥控器短按开麦中，按 Mac 键盘短按关闭会话", testCrossDeviceStopFromKeyboard)
        run("魔鬼 Case：外部输入法主动点开麦时默认归属电脑麦", testExternalMouseStartDefaultsToMacMic)
        run("魔鬼 Case：macOS 14.2 之前兼容模式（长按 + 短按）", testCompatibilityModePre142)
        run("魔鬼 Case：免驱态 / 仅电脑麦绝不触发虚拟输出与系统麦接管", testDriverlessAndMacOnlyNeverHijackSystemMic)
        run("魔鬼 Case：双麦合并 120ms 对齐标志与环形缓冲零溢出", testDualMixDelayAndRingBufferZeroOverflow)
        run("自定义组合与左右单修饰语音触发键编解码持久化", testVoiceTriggerShortcutEncoding)
        run("回归 Case：免驱态关闭双麦后点击「仅电脑麦」立即恢复开启", testDriverlessMuteAllThenSelectMacOnlyReenables)
        run("回归 Case：驱动态关闭双麦后点击任意策略或独立开关立即恢复", testDriverMuteAllAndToggleRecovery)
        run("新功能：遥控器 3 档灵敏度 DSP 增益与软限幅参数校验", testRemoteGainPresets)
        run("新功能：按前台应用自动推荐预设（IDE/终端 vs 办公/本App）", testAutoSwitchPresetByBundleID)
        run("新功能：预设独立档案无损切换与长按第二功能持久化", testPerPresetProfileAndLongPressPersistence)
        run("新功能：Vibe Coding 专属动作键码与修饰位校验", testVibeCodingExpandedActions)
        run("新功能：语义化版本比较与 SHA-256 完整性解析校验", testUpdaterSemVerAndSHA256)
        run("新功能：覆盖更新安全目标路径防呆（避开只读卷与隔离区）", testUpdaterSafeTargetResolution)
        run("新功能：真实安全覆盖与旧进程回收流程自测", testAtomicReplaceScriptExecution)
        print("✅ 全部智能随动、VoiceSession & 防冲突自测通过（\(passedCount)/\(passedCount)）")
    }

    // MARK: - 1. 48 种组合穷举真值矩阵

    private static func testRoutingTruthTable48Cases() {
        var checked = 0
        for driverAvailable in [false, true] {
            for allMuted in [false, true] {
                for policy in MicRoutingPolicy.allCases {
                    for source in SessionTriggerSource.allCases {
                        // 待机态：无论任何组合都绝不允许采麦、绝不开虚拟输出、绝不接管系统默认麦
                        let idle = AudioRoutingDecision.resolve(
                            driverAvailable: driverAvailable,
                            allMuted: allMuted,
                            policy: policy,
                            sessionActive: false,
                            triggerSource: source,
                            uiMeterVisible: true
                        )
                        expect(!idle.needsMacCapture && !idle.useRemoteInVirtualOutput && !idle.needsVirtualOutputIO && !idle.needsTransientSystemRoute,
                               "待机态严禁占麦或接管系统麦 (driver=\(driverAvailable), policy=\(policy))")

                        // 激活态
                        let live = AudioRoutingDecision.resolve(
                            driverAvailable: driverAvailable,
                            allMuted: allMuted,
                            policy: policy,
                            sessionActive: true,
                            triggerSource: source,
                            uiMeterVisible: true
                        )
                        if allMuted {
                            expect(!live.needsMacCapture && !live.useRemoteInVirtualOutput && !live.needsVirtualOutputIO && !live.needsTransientSystemRoute,
                                   "双关静音态必须彻底阻断全部采集与接管")
                        } else if !driverAvailable || !policy.requiresDriver {
                            expect(!live.needsVirtualOutputIO && !live.useRemoteInVirtualOutput && !live.needsTransientSystemRoute,
                                   "免驱或仅电脑麦绝不能走虚拟声卡或接管系统默认麦")
                            expect(live.needsDirectMacMeter, "仅电脑麦开窗激活时应提供只读电平动效")
                        } else {
                            expect(live.needsVirtualOutputIO, "驱动态策略 \(policy) 激活时必须开启虚拟输出")
                            switch policy {
                            case .smartByTriggerSource:
                                expect(live.useMacInVirtualOutput != live.useRemoteInVirtualOutput,
                                       "智能随动下 Mac 麦与遥控器麦必须严格互斥（绝不同时混音产生回声）")
                                expect(!live.applyDualMixDelay, "智能随动必须 0ms 零延迟")
                            case .remoteOnly:
                                expect(!live.useMacInVirtualOutput && live.useRemoteInVirtualOutput, "仅遥控器麦必须关闭 Mac 麦")
                            case .dualMix:
                                expect(live.useMacInVirtualOutput && live.useRemoteInVirtualOutput && live.applyDualMixDelay,
                                       "双麦合并必须双开且启用 120ms 对齐")
                            case .macOnly:
                                break
                            }
                        }
                        checked += 1
                    }
                }
            }
        }
        expect(checked == 48, "真值表应完整穷举 48 种组合")
    }

    // MARK: - 2. 智能随动严格互斥不变式

    private static func testSmartAutoSwitchStrictMutualExclusion() {
        let kb = AudioRoutingDecision.resolve(
            driverAvailable: true, allMuted: false, policy: .smartByTriggerSource,
            sessionActive: true, triggerSource: .keyboard, uiMeterVisible: true
        )
        expect(kb.useMacInVirtualOutput && !kb.useRemoteInVirtualOutput && !kb.needsTransientSystemRoute,
               "智能随动-键盘触发：仅 Mac 麦生效、遥控器静音、不切系统默认麦")

        let rem = AudioRoutingDecision.resolve(
            driverAvailable: true, allMuted: false, policy: .smartByTriggerSource,
            sessionActive: true, triggerSource: .remote, uiMeterVisible: true
        )
        expect(!rem.useMacInVirtualOutput && rem.useRemoteInVirtualOutput && rem.needsTransientSystemRoute,
               "智能随动-遥控器触发：仅遥控器麦生效、Mac 麦静默防回声、按需短切虚拟麦")
    }

    // MARK: - 3. 连续交替：键盘 -> 遥控器 -> 键盘

    private static func testSmartAlternatingKeyboardAndRemote() {
        let mock = MockAudioState(observable: true)
        var clock = Date(timeIntervalSince1970: 500)
        var history: [(Bool, SessionTriggerSource)] = []

        let coord = VoiceSessionCoordinator(
            audioState: mock,
            setAudioSessionActive: { active, src in history.append((active, src)) },
            shouldConsumeRemoteAudio: { true },
            sendTrigger: { _ in },
            releaseTrigger: {},
            triggerMode: { .hold },
            now: { clock }
        )
        coord.start()

        // 第 1 句：键盘按住说
        coord.physicalKeyboardTriggerDown()
        mock.emit(state: .active)
        expect(history.last?.0 == true && history.last?.1 == .keyboard, "第 1 句应路由至键盘 Mac 麦")
        coord.physicalKeyboardTriggerUp()
        mock.emit(state: .inactive)
        expect(coord.debugSnapshot.phase == .closed && coord.debugSnapshot.owner == .none, "第 1 句结束后归零")

        // 第 2 句：拿起遥控器长按说
        clock = clock.addingTimeInterval(0.3)
        coord.remoteAudioStarted(reason: 0x03)
        mock.emit(state: .active)
        expect(history.last?.0 == true && history.last?.1 == .remote, "第 2 句应立即切至遥控器麦")
        clock = clock.addingTimeInterval(0.9)
        coord.remoteAudioStopped(reason: 0x02)
        mock.emit(state: .inactive)
        expect(coord.debugSnapshot.phase == .closed && coord.debugSnapshot.owner == .none, "第 2 句结束后归零")

        // 第 3 句：马上再回键盘按住说
        clock = clock.addingTimeInterval(0.2)
        coord.physicalKeyboardTriggerDown()
        mock.emit(state: .active)
        expect(history.last?.0 == true && history.last?.1 == .keyboard, "第 3 句应无缝切回键盘 Mac 麦")
        coord.physicalKeyboardTriggerUp()
        mock.emit(state: .inactive)
        expect(coord.debugSnapshot.phase == .closed, "第 3 句正常闭合")
    }

    // MARK: - 4. 遥控器长按对讲

    private static func testRemoteHoldToTalk() {
        let mock = MockAudioState(observable: true)
        var clock = Date(timeIntervalSince1970: 1000)
        var triggers: [Bool] = []
        var sources: [(Bool, SessionTriggerSource)] = []
        var releaseCount = 0

        let coord = VoiceSessionCoordinator(
            audioState: mock,
            setAudioSessionActive: { active, src in sources.append((active, src)) },
            shouldConsumeRemoteAudio: { true },
            sendTrigger: { triggers.append($0) },
            releaseTrigger: { releaseCount += 1 },
            triggerMode: { .hold },
            now: { clock }
        )
        coord.start()

        coord.remoteAudioStarted(reason: 0x03)
        expect(triggers == [true], "按下遥控器语音键应发出启动触发")
        expect(sources.last?.1 == .remote, "遥控器触发的路由所有权必须为 .remote")

        mock.emit(state: .active)
        expect(coord.debugSnapshot.phase == .open, "输入法进入录音态后会话应转为 open")

        clock = clock.addingTimeInterval(0.8)
        coord.remoteAudioStopped(reason: 0x02)
        expect(triggers == [true, false], "长按松手应发出结束触发")
        expect(releaseCount >= 1, "结束会话必须调用防卡键释放")

        mock.emit(state: .inactive)
        expect(coord.debugSnapshot.phase == .closed, "输入法停止后会话应收敛为 closed")
    }

    // MARK: - 5. 遥控器短按开关 + 续麦

    private static func testRemoteShortTapToggleAndRenew() {
        let mock = MockAudioState(observable: true)
        var clock = Date(timeIntervalSince1970: 2000)
        var triggers: [Bool] = []
        var renewCount = 0
        var lastBypass = false

        let coord = VoiceSessionCoordinator(
            audioState: mock,
            setAudioSessionActive: { _, _ in },
            shouldConsumeRemoteAudio: { true },
            sendTrigger: { triggers.append($0) },
            releaseTrigger: {},
            triggerMode: { .toggle },
            now: { clock }
        )
        coord.onRequestOpenRemoteMic = { bypass in
            renewCount += 1
            lastBypass = bypass
            return .sent
        }
        coord.start()

        // 第一次短按（0.2s）：开启并保持录音，同时触发一次续麦
        coord.remoteAudioStarted(reason: 0x03)
        mock.emit(state: .active)
        clock = clock.addingTimeInterval(0.2)
        coord.remoteAudioStopped(reason: 0x02)
        expect(coord.debugSnapshot.phase == .open, "短按松手后应保持录音开启")
        expect(triggers == [true], "第一次短按不应提前发关闭触发")
        expect(renewCount == 1, "智能随动需要遥控器音频时，短按松手后应请求续麦保持收音")
        expect(lastBypass, "短按续麦必须强制开启直通防抖(bypassDebounce)，彻底杜绝短按丢失录音")

        // 第二次短按：关闭录音
        clock = clock.addingTimeInterval(1.0)
        coord.remoteAudioStarted(reason: 0x03)
        clock = clock.addingTimeInterval(0.18)
        coord.remoteAudioStopped(reason: 0x02)
        expect(triggers == [true, false], "第二次短按应发出关闭触发")
    }

    // MARK: - 6. 遥控器单流超时自动续麦

    private static func testRemoteStreamTimeoutAutoRenew() {
        let mock = MockAudioState(observable: true)
        var renewCount = 0
        let coord = VoiceSessionCoordinator(
            audioState: mock,
            setAudioSessionActive: { _, _ in },
            shouldConsumeRemoteAudio: { true },
            sendTrigger: { _ in },
            releaseTrigger: {},
            triggerMode: { .toggle },
            now: Date.init
        )
        coord.onRequestOpenRemoteMic = { _ in
            renewCount += 1
            return .sent
        }
        coord.start()

        coord.remoteAudioStarted(reason: 0x03)
        mock.emit(state: .active)
        coord.remoteAudioStopped(reason: 0x02) // 短按后续麦（第 1 次）
        coord.remoteAudioStarted(reason: 0x00) // 主机续麦成功
        coord.remoteAudioStopped(reason: 0x08) // 硬件单流超时断流
        expect(renewCount == 2, "长句说话遇到遥控器硬件超时断流应自动静默续麦")
        expect(coord.debugSnapshot.phase == .open, "超时续麦期间不应中断输入法录音")
    }

    // MARK: - 7. 遥控器录音中蓝牙突然断连（0xFB）防卡键

    private static func testRemoteDisconnectDuringActiveSession() {
        let mock = MockAudioState(observable: true)
        var triggers: [Bool] = []
        var releaseCount = 0
        var renewCount = 0

        let coord = VoiceSessionCoordinator(
            audioState: mock,
            setAudioSessionActive: { _, _ in },
            shouldConsumeRemoteAudio: { true },
            sendTrigger: { triggers.append($0) },
            releaseTrigger: { releaseCount += 1 },
            triggerMode: { .hold },
            now: Date.init
        )
        coord.onRequestOpenRemoteMic = { _ in
            renewCount += 1
            return .unavailable
        }
        coord.start()

        coord.remoteAudioStarted(reason: 0x03)
        mock.emit(state: .active)
        // 模拟长按说话中途遥控器没电或走出范围蓝牙断连（0xFB）
        coord.remoteAudioStopped(reason: 0xFB)
        expect(triggers == [true, false], "蓝牙突然断连必须发出结束触发，禁止卡在录音态")
        expect(releaseCount >= 1, "蓝牙突然断连必须强制释放长按修饰键防卡键")
        expect(renewCount == 0, "断连状态严禁盲目重开麦")
        mock.emit(state: .inactive)
        expect(coord.debugSnapshot.phase == .closed && coord.debugSnapshot.owner == .none, "断连后状态机必须干净收敛")
    }

    // MARK: - 8. 键盘录音期间收到迟到遥控器非物理唤醒包不串麦

    private static func testLateRemotePacketCannotHijackKeyboardSession() {
        let mock = MockAudioState(observable: true)
        var lastSource: SessionTriggerSource = .none
        var closeRemoteCount = 0

        let coord = VoiceSessionCoordinator(
            audioState: mock,
            setAudioSessionActive: { _, src in lastSource = src },
            shouldConsumeRemoteAudio: { false },
            sendTrigger: { _ in },
            releaseTrigger: {},
            triggerMode: { .hold },
            now: Date.init
        )
        coord.onRequestCloseRemoteMic = { closeRemoteCount += 1 }
        coord.start()

        coord.physicalKeyboardTriggerDown()
        mock.emit(state: .active)
        expect(lastSource == .keyboard, "键盘开麦归属 .keyboard")

        // 此时遥控器意外发来一个非按键启动包（reason 0x00）
        coord.remoteAudioStarted(reason: 0x00)
        expect(lastSource == .keyboard && coord.debugSnapshot.owner == .keyboard, "迟到遥控器包绝不能劫持键盘会话所有权")
        expect(closeRemoteCount == 1, "应立即主动关闭误唤醒的遥控器麦克风")
    }

    // MARK: - 9. 关闭途中收到迟到 AUDIO_START 必须拒绝

    private static func testLateRemoteStartDuringClosingRejected() {
        let mock = MockAudioState(observable: true)
        var clock = Date(timeIntervalSince1970: 4000)
        var closeRemoteCount = 0

        let coord = VoiceSessionCoordinator(
            audioState: mock,
            setAudioSessionActive: { _, _ in },
            shouldConsumeRemoteAudio: { true },
            sendTrigger: { _ in },
            releaseTrigger: {},
            triggerMode: { .hold },
            now: { clock }
        )
        coord.onRequestCloseRemoteMic = { closeRemoteCount += 1 }
        coord.start()

        coord.remoteAudioStarted(reason: 0x03)
        mock.emit(state: .active)
        clock = clock.addingTimeInterval(0.8)
        coord.remoteAudioStopped(reason: 0x02)
        expect(coord.debugSnapshot.phase == .closing, "松手后等待输入法停止期间应处于 closing")

        let before = closeRemoteCount
        coord.remoteAudioStarted(reason: 0x00)
        expect(coord.debugSnapshot.phase == .closing, "closing 期间迟到 AUDIO_START 不应重新拉起会话")
        expect(closeRemoteCount == before + 1, "closing 期间迟到 AUDIO_START 必须立即发 MIC_CLOSE 压制")
    }

    // MARK: - 10 & 11. 跨设备关麦（键盘开遥控器关 / 遥控器开键盘关）

    private static func testCrossDeviceStopFromRemote() {
        let mock = MockAudioState(observable: true)
        var triggers: [Bool] = []
        let coord = VoiceSessionCoordinator(
            audioState: mock,
            setAudioSessionActive: { _, _ in },
            shouldConsumeRemoteAudio: { false },
            sendTrigger: { triggers.append($0) },
            releaseTrigger: {},
            triggerMode: { .toggle },
            now: Date.init
        )
        coord.start()

        coord.physicalKeyboardTriggerDown()
        mock.emit(state: .active)
        expect(coord.debugSnapshot.owner == .keyboard, "键盘开启归属 .keyboard")

        // 用户改为按遥控器短按关掉本次录音
        coord.remoteAudioStarted(reason: 0x03)
        coord.remoteAudioStopped(reason: 0x02)
        expect(triggers == [false], "已在录音时遥控器短按应发出关闭触发")
        mock.emit(state: .inactive)
        expect(coord.debugSnapshot.phase == .closed, "跨设备关闭后干净收敛")
    }

    private static func testCrossDeviceStopFromKeyboard() {
        let mock = MockAudioState(observable: true)
        var closeRemoteCount = 0
        let coord = VoiceSessionCoordinator(
            audioState: mock,
            setAudioSessionActive: { _, _ in },
            shouldConsumeRemoteAudio: { true },
            sendTrigger: { _ in },
            releaseTrigger: {},
            triggerMode: { .toggle },
            now: Date.init
        )
        coord.onRequestCloseRemoteMic = { closeRemoteCount += 1 }
        coord.start()

        coord.remoteAudioStarted(reason: 0x03)
        mock.emit(state: .active)
        coord.remoteAudioStopped(reason: 0x02) // 短按保持开启
        expect(coord.debugSnapshot.phase == .open && coord.debugSnapshot.owner == .remote, "遥控器短按保持开启")

        // 用户改按 Mac 键盘短按关闭录音
        coord.physicalKeyboardTriggerDown()
        expect(closeRemoteCount >= 1, "键盘接管关闭时必须同步关闭遥控器麦克风")
        mock.emit(state: .inactive)
        expect(coord.debugSnapshot.phase == .closed && coord.debugSnapshot.owner == .none, "跨设备关闭后归零")
    }

    // MARK: - 12. 鼠标直接点第三方输入法开麦默认归属电脑麦

    private static func testExternalMouseStartDefaultsToMacMic() {
        let mock = MockAudioState(observable: true)
        var lastSource: SessionTriggerSource = .none
        let coord = VoiceSessionCoordinator(
            audioState: mock,
            setAudioSessionActive: { _, src in lastSource = src },
            shouldConsumeRemoteAudio: { false },
            sendTrigger: { _ in },
            releaseTrigger: {},
            triggerMode: { .hold },
            now: Date.init
        )
        coord.start()

        mock.emit(state: .active)
        expect(coord.debugSnapshot.phase == .open && coord.debugSnapshot.owner == .keyboard && lastSource == .keyboard,
               "用户用鼠标直接点输入法录音时，智能随动应默认走电脑麦")
        mock.emit(state: .inactive)
        expect(coord.debugSnapshot.phase == .closed, "结束后归零")
    }

    // MARK: - 13. macOS <14.2 兼容模式

    private static func testCompatibilityModePre142() {
        let mock = MockAudioState(observable: false, initialState: .unavailable)
        var clock = Date(timeIntervalSince1970: 3000)
        let coord = VoiceSessionCoordinator(
            audioState: mock,
            setAudioSessionActive: { _, _ in },
            shouldConsumeRemoteAudio: { false },
            sendTrigger: { _ in },
            releaseTrigger: {},
            triggerMode: { .hold },
            now: { clock }
        )
        coord.start()

        coord.remoteAudioStarted(reason: 0x03)
        expect(coord.debugSnapshot.phase == .open, "兼容模式下按下应立即进入 open")
        clock = clock.addingTimeInterval(0.75)
        coord.remoteAudioStopped(reason: 0x02)
        expect(coord.debugSnapshot.phase == .closed, "兼容模式长按松手应直接关闭")
    }

    // MARK: - 14. 免驱与仅电脑麦绝不接管系统麦

    private static func testDriverlessAndMacOnlyNeverHijackSystemMic() {
        for src in SessionTriggerSource.allCases {
            let d1 = AudioRoutingDecision.resolve(
                driverAvailable: false, allMuted: false, policy: .smartByTriggerSource,
                sessionActive: true, triggerSource: src, uiMeterVisible: true
            )
            let d2 = AudioRoutingDecision.resolve(
                driverAvailable: true, allMuted: false, policy: .macOnly,
                sessionActive: true, triggerSource: src, uiMeterVisible: true
            )
            expect(!d1.needsTransientSystemRoute && !d1.needsVirtualOutputIO, "免驱态绝不接管系统麦")
            expect(!d2.needsTransientSystemRoute && !d2.needsVirtualOutputIO, "仅电脑麦绝不接管系统麦")
        }
    }

    // MARK: - 15. 双麦合并 120ms 与环形缓冲零溢出

    private static func testDualMixDelayAndRingBufferZeroOverflow() {
        let dual = AudioRoutingDecision.resolve(
            driverAvailable: true, allMuted: false, policy: .dualMix,
            sessionActive: true, triggerSource: .keyboard, uiMeterVisible: true
        )
        expect(dual.applyDualMixDelay && dual.useMacInVirtualOutput && dual.useRemoteInVirtualOutput,
               "双麦合并必须双路同时开启并应用 120ms 对齐延迟")

        let ring = FloatRingBuffer(capacity: 1024)
        for i in 0..<2048 {
            ring.push(Float(i))
        }
        expect(ring.count == 1024, "环形缓冲满时必须维持固定容量")
        expect(ring.pop() == 1024.0, "溢出后应自动丢弃最旧样本保留最新窗口")
    }

    // MARK: - 16. 自定义语音触发键持久化

    private static func testVoiceTriggerShortcutEncoding() {
        let custom = VoiceTriggerShortcut.customCombo(keyCode: 0x31, flags: [.maskAlternate], label: "⌥ Space")
        let data = try! JSONEncoder().encode(custom)
        let decoded = try! JSONDecoder().decode(VoiceTriggerShortcut.self, from: data)
        expect(decoded == custom && decoded.isCustomRecorded, "自定义组合语音触发键必须完整持久化")

        let leftOpt = VoiceTriggerShortcut.customModifier(.leftOption)
        let d2 = try! JSONEncoder().encode(leftOpt)
        let dec2 = try! JSONDecoder().decode(VoiceTriggerShortcut.self, from: d2)
        expect(dec2.modifier == .leftOption && dec2.keyCode == UInt16(ModifierTriggerKey.leftOption.keyCode),
               "左右单修饰键必须准确区分并持久化")
    }

    // MARK: - 17. 免驱态关闭双麦后点击「仅电脑麦」必须立即恢复开启

    private static func testDriverlessMuteAllThenSelectMacOnlyReenables() {
        let savedPolicy = AppStorage.micPolicy
        defer { AppStorage.micPolicy = savedPolicy }

        let vm = AppViewModel()
        vm.driverInstalled = false
        vm.micPolicy = .macOnly
        vm.macMonitoringEnabled = true
        vm.allMuted = false

        var macMonitorEvents: [Bool] = []
        vm.onMacMonitoringToggled = { macMonitorEvents.append($0) }

        // 1. 点击「关闭双麦」
        vm.toggleMuteAll()
        expect(vm.isAllMicsClosed && !vm.isMacEnabled, "免驱态关闭双麦后必须处于全关状态")
        expect(macMonitorEvents == [false], "关闭双麦必须触发停止采麦监听回调")

        // 2. 此时直接点击顶部「仅电脑麦」
        vm.selectPolicy(.macOnly)
        expect(!vm.isAllMicsClosed && vm.isMacEnabled && vm.macMonitoringEnabled,
               "免驱态关闭双麦后点击「仅电脑麦」必须立即恢复开启 MacBook 麦克风")
        expect(macMonitorEvents == [false, true], "点击「仅电脑麦」恢复时必须触发开启采麦回调")
    }

    // MARK: - 18. 驱动态关闭双麦后点击任意策略或单路开关立即恢复

    private static func testDriverMuteAllAndToggleRecovery() {
        let savedPolicy = AppStorage.micPolicy
        defer { AppStorage.micPolicy = savedPolicy }

        let vm = AppViewModel()
        vm.driverInstalled = true
        vm.micPolicy = .smartByTriggerSource
        vm.allMuted = false

        var mutedEvents: [Bool] = []
        vm.onAllMutedChanged = { mutedEvents.append($0) }

        // 1. 一键关闭双麦
        vm.toggleMuteAll()
        expect(vm.isAllMicsClosed && !vm.isMacEnabled && !vm.isRemoteEnabled, "驱动态一键关闭双麦后两路都应关闭")

        // 2. 点击「仅电脑麦」立即解除静音并切入仅电脑麦
        vm.selectPolicy(.macOnly)
        expect(!vm.isAllMicsClosed && vm.isMacEnabled && !vm.isRemoteEnabled && vm.micPolicy == .macOnly,
               "驱动态关闭双麦后点击「仅电脑麦」应立即解除静音并只开电脑麦")

        // 3. 单独把电脑麦拨关，进入双关状态；再单独拨开遥控器麦，应仅开遥控器麦
        vm.toggleMacChannel()
        expect(vm.isAllMicsClosed && !vm.isMacEnabled && !vm.isRemoteEnabled, "仅电脑麦状态下关闭电脑麦应进入双关状态")
        vm.toggleRemoteChannel()
        expect(!vm.isAllMicsClosed && !vm.isMacEnabled && vm.isRemoteEnabled && vm.micPolicy == .remoteOnly,
               "双关状态下打开遥控器麦应进入仅遥控器麦")
        expect(mutedEvents.contains(true) && mutedEvents.last == false, "静音解除事件应完整同步到底层音频管道")
    }

    // MARK: - 19. 遥控器 3 档灵敏度 DSP 增益

    private static func testRemoteGainPresets() {
        expect(RemoteMicGainPreset.near.linearGain == 5.0, "近场档位应为 5.0 (+14dB)")
        expect(RemoteMicGainPreset.standard.linearGain == 10.0, "标准档位应为 10.0 (+20dB)")
        expect(RemoteMicGainPreset.far.linearGain == 20.0, "远场档位应为 20.0 (+26dB)")
        AudioPipe.shared.setRemoteGainPreset(.far)
        AudioPipe.shared.setRemoteGainPreset(AppStorage.remoteMicGainPreset)
    }

    // MARK: - 20. 按前台应用自动推荐预设

    private static func testAutoSwitchPresetByBundleID() {
        expect(RemoteMappingPreset.recommendedPreset(forBundleID: "com.todesktop.230313mzl4w4u92") == .vibe, "Cursor 应匹配 Vibe Coding")
        expect(RemoteMappingPreset.recommendedPreset(forBundleID: "com.microsoft.VSCode") == .vibe, "VS Code 应匹配 Vibe Coding")
        expect(RemoteMappingPreset.recommendedPreset(forBundleID: "com.apple.Terminal") == .vibe, "终端应匹配 Vibe Coding")
        expect(RemoteMappingPreset.recommendedPreset(forBundleID: "com.google.antigravity") == .vibe, "Antigravity 应匹配 Vibe Coding")
        expect(RemoteMappingPreset.recommendedPreset(forBundleID: "com.apple.Safari") == .office, "Safari 应匹配日常办公")
        expect(RemoteMappingPreset.recommendedPreset(forBundleID: "com.tencent.xinWeChat") == .office, "微信应匹配日常办公")
        expect(RemoteMappingPreset.recommendedPreset(forBundleID: AppStorage.bundleIdentifier) == nil, "切回 G9NVibe 自身不应触发自动切换打扰编辑")
    }

    // MARK: - 21. 预设独立档案无损切换与长按第二功能持久化

    private static func testPerPresetProfileAndLongPressPersistence() {
        let savedPreset = AppStorage.remotePresetRaw
        let savedSnapshots = AppStorage.remoteProfileSnapshotsData
        let savedMappings = AppStorage.remoteMappingsData
        let savedCustom = AppStorage.remoteCustomShortcutsData
        defer {
            AppStorage.remotePresetRaw = savedPreset
            AppStorage.remoteProfileSnapshotsData = savedSnapshots
            AppStorage.remoteMappingsData = savedMappings
            AppStorage.remoteCustomShortcutsData = savedCustom
        }

        let store = RemoteMappingStore.shared
        let okBtn = RemoteProfiles.g9n9nButtons.first(where: { $0.id == "07" })!
        let upBtn = RemoteProfiles.g9n9nButtons.first(where: { $0.id == "03" })!
        expect(okBtn.supportsLongPress && !upBtn.supportsLongPress, "仅功能键开放长按，方向键必须保持 0ms 瞬发")

        store.applyPreset(.vibe)
        store.setTarget(.aiOpenChat, for: okBtn.id)
        store.setLongPressTarget(.shiftReturn, for: okBtn.id)
        expect(store.hasActiveLongPress(for: okBtn), "配置长按动作后必须激活双功能")

        // 切到日常办公后再切回 Vibe Coding，验证两套档案互不覆盖
        store.applyPreset(.office)
        expect(store.longPressTarget(for: okBtn) == .disabled, "日常办公档案不应被 Vibe Coding 的长按污染")
        store.applyPreset(.vibe)
        expect(store.target(for: okBtn) == .aiOpenChat && store.longPressTarget(for: okBtn) == .shiftReturn,
               "切回 Vibe Coding 必须完整保留自定义短按与长按动作")

        // 清除长按应恢复为无长按态
        store.setLongPressTarget(.disabled, for: okBtn.id)
        expect(!store.hasActiveLongPress(for: okBtn), "设为禁用后应关闭长按恢复 0ms 瞬发")
    }

    // MARK: - 22. Vibe Coding 专属动作键码与修饰位校验

    private static func testVibeCodingExpandedActions() {
        let checks: [(RemoteMappingTarget, CGKeyCode, CGEventFlags)] = [
            (.shiftReturn, 0x24, [.maskShift]),
            (.commandShiftZ, 0x06, [.maskCommand, .maskShift]),
            (.commandA, 0x00, [.maskCommand]),
            (.aiOpenChat, 0x25, [.maskCommand]),
            (.aiAccept, 0x24, [.maskCommand]),
            (.areaScreenshot, 0x15, [.maskControl, .maskCommand, .maskShift]),
            (.newTab, 0x11, [.maskCommand]),
        ]
        for (action, expectedCode, expectedFlags) in checks {
            guard let spec = action.keyboardSpec else {
                expect(false, "\(action.rawValue) 必须提供有效 keyboardSpec")
                return
            }
            expect(spec.keyCode == expectedCode && spec.flags == expectedFlags,
                   "\(action.rawValue) 键码或修饰位不符合预期")
        }
    }

    // MARK: - 23. 更新器 SemVer 与 SHA-256 校验

    private static func testUpdaterSemVerAndSHA256() {
        expect(AppUpdater.isVersion("1.0.10", newerThan: "1.0.2"), "1.0.10 必须大于 1.0.2（不能按字典序比较）")
        expect(AppUpdater.isVersion("v1.2.0", newerThan: "1.1.9"), "v1.2.0 必须大于 1.1.9")
        expect(AppUpdater.isVersion("2.0", newerThan: "1.9.9"), "2.0 必须大于 1.9.9")
        expect(!AppUpdater.isVersion("v1.0.0", newerThan: "1.0.0"), "相同版本号不应判定为有更新")
        expect(!AppUpdater.isVersion("0.9.9", newerThan: "1.0.0"), "低版本不应判定为有更新")

        let validLine = "b9441ab4b4d5fc0375547a49d8b420cf15b88a4e27289f86947624dee7be815d  G9NVibe-1.0.0.dmg\n"
        expect(AppUpdater.parseSHA256Text(validLine) == "b9441ab4b4d5fc0375547a49d8b420cf15b88a4e27289f86947624dee7be815d",
               "应正确解析标准 shasum 输出")
        expect(AppUpdater.parseSHA256Text("not-a-valid-hash") == nil, "非法哈希字符串必须被拒绝")
    }

    // MARK: - 24. 覆盖安装目标路径安全防呆

    private static func testUpdaterSafeTargetResolution() {
        let normalApp = URL(fileURLWithPath: "/Applications/G9NVibe.app")
        expect(AppUpdater.resolveInstallTargetURL(bundleURL: normalApp).path == "/Applications/G9NVibe.app",
               "正常应用程序目录应原地覆盖")

        let dmgVolumeApp = URL(fileURLWithPath: "/Volumes/G9NVibe 1.0.0/G9NVibe.app")
        expect(AppUpdater.resolveInstallTargetURL(bundleURL: dmgVolumeApp).path == "/Applications/G9NVibe.app",
               "从只读 DMG 卷直接运行时必须重定向安装至 /Applications")

        let translocated = URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/ABC/d/G9NVibe.app")
        expect(AppUpdater.resolveInstallTargetURL(bundleURL: translocated).path == "/Applications/G9NVibe.app",
               "处于 AppTranslocation 隔离区时必须重定向安装至 /Applications")
    }

    // MARK: - 25. 真实安全静默覆盖与防卡死替换流程自测

    private static func testAtomicReplaceScriptExecution() {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("G9N9N-UpdateTest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let targetDir = tempRoot.appendingPathComponent("TargetApp.app", isDirectory: true)
        let stagedDir = tempRoot.appendingPathComponent("StagedApp.app", isDirectory: true)
        let scriptDir = tempRoot.appendingPathComponent("ScriptDir", isDirectory: true)
        try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: stagedDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: scriptDir, withIntermediateDirectories: true)

        let oldFile = targetDir.appendingPathComponent("version.txt")
        let newFile = stagedDir.appendingPathComponent("version.txt")
        try? "1.0.0".write(to: oldFile, atomically: true, encoding: .utf8)
        try? "1.0.1".write(to: newFile, atomically: true, encoding: .utf8)

        // 模拟一个旧进程（启动一个后台 sleep 进程）
        let mockProc = Process()
        mockProc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        mockProc.arguments = ["5"]
        try? mockProc.run()
        let mockPID = mockProc.processIdentifier

        let scriptURL = scriptDir.appendingPathComponent("test-replace.sh")
        let backupPath = tempRoot.appendingPathComponent(".TargetApp.backup-\(mockPID).app").path
        let newSlotPath = tempRoot.appendingPathComponent(".TargetApp.new-\(mockPID).app").path

        let script = """
        #!/bin/zsh
        set -e
        TARGET='\(targetDir.path)'
        STAGED='\(stagedDir.path)'
        BACKUP='\(backupPath)'
        NEWSLOT='\(newSlotPath)'

        for _ in {1..10}; do
          if ! kill -0 \(mockPID) 2>/dev/null; then break; fi
          sleep 0.05
        done
        kill -9 \(mockPID) 2>/dev/null || true

        rm -rf "$NEWSLOT" "$BACKUP"
        /usr/bin/ditto "$STAGED" "$NEWSLOT"
        if [ -d "$TARGET" ]; then
          mv "$TARGET" "$BACKUP"
        fi
        mv "$NEWSLOT" "$TARGET"
        rm -rf "$BACKUP"
        """

        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["+x", scriptURL.path])

        let runScript = Process()
        runScript.executableURL = URL(fileURLWithPath: "/bin/zsh")
        runScript.arguments = [scriptURL.path]
        try? runScript.run()
        runScript.waitUntilExit()

        expect(runScript.terminationStatus == 0, "替换脚本执行退出码必须为 0")
        let finalVersion = (try? String(contentsOf: oldFile, encoding: .utf8)) ?? ""
        expect(finalVersion == "1.0.1", "目标目录内容必须成功无损升级为新版 (当前: \(finalVersion))")
        expect(!mockProc.isRunning, "旧进程必须已被强制回收")
    }
}
#endif
