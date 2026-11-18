import SwiftUI

/// 1:1 精准复刻原图 Google Chromecast (G9N9N) 遥控器纯矢量交互视图（零位图图片，极低内存占用）
struct G9N9NVectorView: View {
    @Binding var selectedKeyID: String
    let isVoiceActive: Bool
    var isConnected: Bool = false
    var isLedPulsing: Bool = false
    let palette: VibePalette
    let onSelectKey: (String) -> Void

    @State private var breathePhase = false

    private let baseWidth: CGFloat = 180
    private let baseHeight: CGFloat = 460

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / baseWidth, geo.size.height / baseHeight)
            let w = baseWidth * scale
            let h = baseHeight * scale

            ZStack(alignment: .topLeading) {
                // 1. 右侧两枚微凸实体音量侧键
                volumeSideButton(id: "0C", yTop: 106, yBot: 141.5, scale: scale)
                volumeSideButton(id: "0D", yTop: 145, yBot: 180, scale: scale)

                // 2. 鹅卵石胶囊机身（暖瓷白渐变 + 微高光描边）
                RoundedRectangle(cornerRadius: 68 * scale)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.99, green: 0.99, blue: 0.98),
                                Color(red: 0.957, green: 0.957, blue: 0.945),
                                Color(red: 0.906, green: 0.902, blue: 0.878)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 68 * scale)
                            .stroke(Color(red: 0.81, green: 0.808, blue: 0.78), lineWidth: 1.2 * scale)
                    )
                    .frame(width: 136 * scale, height: 436 * scale)
                    .offset(x: 22 * scale, y: 12 * scale)
                    .shadow(color: Color.black.opacity(palette.isDark ? 0.55 : 0.16), radius: 14 * scale, x: 0, y: 10 * scale)

                // 3. 顶部极简同心圆环 D-Pad（4 个 90° 交互扇区 + 中央确认圆键）
                dpadRing(scale: scale)

                // 4. 第一排：返回键 (0B) + 黑色四点语音键 (voice)
                roundKey(id: "0B", cx: 58, cy: 171, r: 22, scale: scale) { selected in
                    BackArrowShape()
                        .stroke(selected ? Color.white : Color(white: 0.09), style: StrokeStyle(lineWidth: 2.4 * scale, lineCap: .round, lineJoin: .round))
                        .frame(width: 15 * scale, height: 12 * scale)
                }

                voiceKey(cx: 122, cy: 171, r: 22, scale: scale)

                // 5. 第二排：Home 键 (0A) + 静音键 (08)
                roundKey(id: "0A", cx: 58, cy: 227, r: 22, scale: scale) { selected in
                    HomeIconShape()
                        .fill(selected ? Color.white : Color(white: 0.09))
                        .frame(width: 15 * scale, height: 14.5 * scale)
                }

                roundKey(id: "08", cx: 122, cy: 227, r: 22, scale: scale) { selected in
                    HStack(spacing: 3 * scale) {
                        SpeakerConeShape()
                            .fill(selected ? Color.white : Color(white: 0.09))
                            .frame(width: 9 * scale, height: 14 * scale)
                        CrossMarkShape()
                            .stroke(selected ? Color.white : Color(white: 0.09), style: StrokeStyle(lineWidth: 2.0 * scale, lineCap: .round))
                            .frame(width: 6 * scale, height: 6 * scale)
                    }
                }

                // 6. 第三排：YouTube (0E) + NETFLIX (0F) 正圆键
                roundKey(id: "0E", cx: 58, cy: 283, r: 22, scale: scale) { selected in
                    Text("YouTube")
                        .font(.system(size: 9.8 * scale, weight: .heavy))
                        .tracking(-0.4 * scale)
                        .foregroundColor(selected ? Color.white : Color(white: 0.09))
                }

                roundKey(id: "0F", cx: 122, cy: 283, r: 22, scale: scale) { selected in
                    Text("NETFLIX")
                        .font(.system(size: 8.8 * scale, weight: .heavy))
                        .tracking(0.2 * scale)
                        .foregroundColor(selected ? Color.white : Color(white: 0.09))
                }

                // 7. 第四排：水平胶囊内凹槽 + 电源键 (01) + 中央微型 LED + 信源键 (11)
                RoundedRectangle(cornerRadius: 16 * scale)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.867, green: 0.863, blue: 0.839), Color(red: 0.96, green: 0.958, blue: 0.945)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16 * scale)
                            .stroke(Color(red: 0.84, green: 0.836, blue: 0.81), lineWidth: 0.8 * scale)
                    )
                    .frame(width: 96 * scale, height: 32 * scale)
                    .offset(x: 42 * scale, y: 321 * scale)

                roundKey(id: "01", cx: 58, cy: 337, r: 12.5, scale: scale) { selected in
                    Image(systemName: "power")
                        .font(.system(size: 10.5 * scale, weight: .semibold))
                        .foregroundColor(selected ? Color.white : Color(white: 0.09))
                }

                // 中央微型 LED 短条（录音时点亮朱砂橙）
                RoundedRectangle(cornerRadius: 1.6 * scale)
                    .fill(isVoiceActive ? palette.brand : Color(white: 0.21))
                    .frame(width: 8.4 * scale, height: 3.2 * scale)
                    .offset(x: 85.8 * scale, y: 335.4 * scale)

                roundKey(id: "11", cx: 122, cy: 337, r: 12.5, scale: scale) { selected in
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 9.5 * scale, weight: .semibold))
                        .foregroundColor(selected ? Color.white : Color(white: 0.09))
                }

                // 8. 遥控器底部正中央真机白色透光 LED 状态灯（未连微凹暗点 / 已连柔和暖白呼吸 / 按键或语音瞬间高亮脉冲）
                bottomWhiteLED(scale: scale)
            }
            .frame(width: w, height: h)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                breathePhase = true
            }
        }
    }

    @ViewBuilder
    private func bottomWhiteLED(scale: CGFloat) -> some View {
        let activePulse = isVoiceActive || isLedPulsing
        let glowOn = isConnected || activePulse
        ZStack {
            // 扩散白光晕（脉冲时放大高亮，已连接时柔和呼吸）
            if glowOn {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(activePulse ? 0.96 : (breathePhase ? 0.80 : 0.45)),
                                Color(red: 0.85, green: 0.92, blue: 1.0).opacity(activePulse ? 0.55 : 0.18),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 1 * scale,
                            endRadius: (activePulse ? 18 : 12) * scale
                        )
                    )
                    .frame(width: (activePulse ? 36 : 24) * scale, height: (activePulse ? 36 : 24) * scale)
                    .animation(.easeOut(duration: 0.22), value: activePulse)
            }

            // 实体微凹透光灯罩底座
            Circle()
                .fill(Color(red: 0.80, green: 0.796, blue: 0.77))
                .frame(width: 7.4 * scale, height: 7.4 * scale)

            // 中心白色 LED 灯芯
            Circle()
                .fill(
                    glowOn
                        ? Color.white
                        : Color(red: 0.86, green: 0.856, blue: 0.835)
                )
                .frame(width: 5.2 * scale, height: 5.2 * scale)
                .shadow(color: glowOn ? Color.white.opacity(activePulse ? 1.0 : 0.75) : .clear, radius: (activePulse ? 5 : 2.5) * scale)
        }
        .position(x: 90 * scale, y: 406 * scale)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func volumeSideButton(id: String, yTop: CGFloat, yBot: CGFloat, scale: CGFloat) -> some View {
        let selected = selectedKeyID == id
        RoundedRectangle(cornerRadius: 3 * scale)
            .fill(selected ? palette.brand : Color(red: 0.918, green: 0.914, blue: 0.894))
            .overlay(
                RoundedRectangle(cornerRadius: 3 * scale)
                    .stroke(selected ? palette.brand : Color(red: 0.72, green: 0.71, blue: 0.68), lineWidth: 0.9 * scale)
            )
            .frame(width: 7 * scale, height: (yBot - yTop) * scale)
            .offset(x: 155 * scale, y: yTop * scale)
            .onTapGesture { onSelectKey(id) }
    }

    @ViewBuilder
    private func dpadRing(scale: CGFloat) -> some View {
        let cx: CGFloat = 90 * scale
        let cy: CGFloat = 80 * scale
        let outerR: CGFloat = 60 * scale
        let innerR: CGFloat = 22.5 * scale

        ZStack {
            // 外环底盘
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.96), Color.white, Color(red: 0.925, green: 0.922, blue: 0.902)],
                        center: .center,
                        startRadius: 0,
                        endRadius: outerR
                    )
                )
                .overlay(Circle().stroke(Color(white: 0.49), lineWidth: 1 * scale))
                .frame(width: outerR * 2, height: outerR * 2)

            // 4 个 90° 环形交互扇区：上(03)、右(06)、下(04)、左(05)
            dpadSector(id: "03", startDeg: -135, endDeg: -45, innerR: innerR, outerR: outerR)
            dpadSector(id: "06", startDeg: -45, endDeg: 45, innerR: innerR, outerR: outerR)
            dpadSector(id: "04", startDeg: 45, endDeg: 135, innerR: innerR, outerR: outerR)
            dpadSector(id: "05", startDeg: 135, endDeg: 225, innerR: innerR, outerR: outerR)

            // 中央确认键 (07)
            let okSelected = selectedKeyID == "07"
            Circle()
                .fill(
                    okSelected
                        ? AnyShapeStyle(palette.brand)
                        : AnyShapeStyle(LinearGradient(colors: [.white, Color(red: 0.95, green: 0.95, blue: 0.93)], startPoint: .top, endPoint: .bottom))
                )
                .overlay(Circle().stroke(okSelected ? palette.brand : Color(white: 0.46), lineWidth: 1 * scale))
                .frame(width: innerR * 2, height: innerR * 2)
                .onTapGesture { onSelectKey("07") }
        }
        .position(x: cx, y: cy)
    }

    @ViewBuilder
    private func dpadSector(id: String, startDeg: Double, endDeg: Double, innerR: CGFloat, outerR: CGFloat) -> some View {
        let selected = selectedKeyID == id
        AnnularSectorShape(startAngle: .degrees(startDeg), endAngle: .degrees(endDeg), innerRadius: innerR, outerRadius: outerR)
            .fill(selected ? palette.brand.opacity(0.32) : Color.clear)
            .contentShape(AnnularSectorShape(startAngle: .degrees(startDeg), endAngle: .degrees(endDeg), innerRadius: innerR, outerRadius: outerR))
            .frame(width: outerR * 2, height: outerR * 2)
            .onTapGesture { onSelectKey(id) }
    }

    @ViewBuilder
    private func roundKey<Glyph: View>(
        id: String,
        cx: CGFloat,
        cy: CGFloat,
        r: CGFloat,
        scale: CGFloat,
        @ViewBuilder glyph: (Bool) -> Glyph
    ) -> some View {
        let selected = selectedKeyID == id
        ZStack {
            Circle()
                .fill(
                    selected
                        ? AnyShapeStyle(palette.brand)
                        : AnyShapeStyle(LinearGradient(colors: [.white, Color(red: 0.95, green: 0.95, blue: 0.93)], startPoint: .top, endPoint: .bottom))
                )
                .overlay(
                    Circle().stroke(selected ? palette.brand : Color(white: 0.48), lineWidth: 0.95 * scale)
                )
                .frame(width: r * 2 * scale, height: r * 2 * scale)
            glyph(selected)
        }
        .position(x: cx * scale, y: cy * scale)
        .onTapGesture { onSelectKey(id) }
    }

    @ViewBuilder
    private func voiceKey(cx: CGFloat, cy: CGFloat, r: CGFloat, scale: CGFloat) -> some View {
        let highlighted = (selectedKeyID == "voice") || isVoiceActive
        ZStack {
            Circle()
                .fill(highlighted ? palette.brand : Color(white: 0.06))
                .frame(width: r * 2 * scale, height: r * 2 * scale)
            // 原图标志性 4 颗错落白色圆点
            ZStack(alignment: .topLeading) {
                Circle().fill(Color.white).frame(width: 10.2 * scale, height: 10.2 * scale).offset(x: 0, y: 1.5 * scale)
                Circle().fill(Color.white).frame(width: 5.5 * scale, height: 5.5 * scale).offset(x: 12.1 * scale, y: 9.8 * scale)
                Circle().fill(Color.white).frame(width: 4.0 * scale, height: 4.0 * scale).offset(x: 12.8 * scale, y: 4.0 * scale)
                Circle().fill(Color.white).frame(width: 2.3 * scale, height: 2.3 * scale).offset(x: 17.6 * scale, y: 2.2 * scale)
            }
            .frame(width: 20.5 * scale, height: 16 * scale)
        }
        .position(x: cx * scale, y: cy * scale)
        .onTapGesture { onSelectKey("voice") }
    }
}

// MARK: - 矢量基础几何 Shape

private struct AnnularSectorShape: Shape {
    let startAngle: Angle
    let endAngle: Angle
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: center, radius: outerRadius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        p.addArc(center: center, radius: innerRadius, startAngle: endAngle, endAngle: startAngle, clockwise: true)
        p.closeSubpath()
        return p
    }
}

private struct BackArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.maxY))
        return p
    }
}

private struct HomeIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.44))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.34, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.34, y: rect.minY + rect.height * 0.67))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.66, y: rect.minY + rect.height * 0.67))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.66, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.44))
        p.closeSubpath()
        return p
    }
}

private struct SpeakerConeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.31))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.31))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.69))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.69))
        p.closeSubpath()
        return p
    }
}

private struct CrossMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return p
    }
}
