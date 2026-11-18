import Foundation

/// ATVV 与 IMA ADPCM 协议回归自测入口（由 Scripts/run-self-tests.sh 编译执行）
private func assertTrue(_ cond: Bool, _ msg: String) {
    if !cond {
        fputs("❌ 协议自测失败: \(msg)\n", stderr)
        exit(1)
    }
}

func runProtocolSelfTests() {
    let proto = ATVVProtocol()

    // 1. 解析 ATVV v1.0 能力包（G9N9N 标准响应格式）
    let capsData = Data([0x0B, 0x01, 0x00, 0x02, 0x01, 0x00, 0x86])
    guard case .capabilities(let caps) = proto.parseControl(capsData) else {
        assertTrue(false, "无法解析 ATVV v1.0 能力包")
        return
    }
    assertTrue(caps.version == .v10, "协议版本应为 1.0")
    assertTrue(caps.selectedCodec == .adpcm16k, "采样率应选中 ADPCM 16kHz")
    try! proto.acceptCapabilities(caps)

    // 2. 验证物理按键按下 AUDIO_START (reason=0x03) 与松开 AUDIO_STOP (reason=0x02)
    let startEvt = proto.parseControl(Data([0x04, 0x03, 0x02, 0x01]))
    assertTrue(startEvt == .audioStart(reason: 0x03, codec: .adpcm16k, streamID: 0x01), "应正确解析 AUDIO_START(0x03)")

    let stopEvt = proto.parseControl(Data([0x00, 0x02]))
    assertTrue(stopEvt == .audioStop(reason: 0x02), "应正确解析 AUDIO_STOP(0x02)")

    // 3. 验证 AUDIO_SYNC 在 AUDIO_START 之前到达不被重置丢失
    proto.prepareForAudioStream()
    proto.applyAudioSync(codec: .adpcm16k, sequence: 7, predictor: 120, stepIndex: 10)
    proto.beginAudioStream(codec: .adpcm16k)

    let audioPayload = Data([0x12, 0x34, 0x56, 0x78])
    guard let decoded = proto.decodeAudio(audioPayload) else {
        assertTrue(false, "ADPCM 解码失败")
        return
    }
    assertTrue(decoded.sequence == 7, "前置 AUDIO_SYNC 序号应被保留")
    assertTrue(decoded.samples.count == 8, "4 字节 ADPCM 应解码出 8 个 Int16 采样")

    print("✅ 全部 ATVV & ADPCM 协议自测通过")
}

runProtocolSelfTests()
