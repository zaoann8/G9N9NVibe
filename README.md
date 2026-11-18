# G9NVibe

> 把你的 Google Chromecast (`G9N9N`) 语音遥控器，变成 macOS 原生 **Vibe Coding 实体声控编程与效率控制器**。
>
> - **产品官网**：<https://zaoann8.github.io/G9N9NVibe/>
> - **下载最新版 DMG**：<https://github.com/zaoann8/G9N9NVibe/releases/latest>

## 核心特点

- **开包即用 · 系统麦永不常驻接管**：拖进「应用程序」直接用 MacBook / AirPods 麦克风工作；需要离桌对着遥控器近场说话时，点击「一键启用」触控 ID 授权 1 秒自动部署内置纯 C 虚拟声卡（随时可一键无痕卸载）。
- **智能随动双麦无冲突融合**：提供 **仅电脑麦 / 智能随动（推荐）/ 仅遥控器麦 / 双麦合并** 4 档路由与 **一键关闭双麦**。按键盘自动用电脑麦、按遥控器自动用遥控器麦，严格按需采麦（待机绝不常亮橙灯、不拖垮 AirPods 音质），异常退出自动还原系统默认麦。
- **真实硬件电量 & 3 档 DSP 收音灵敏度**：原生读取 G9N9N 蓝牙标准电池服务（`0x180F` / `0x2A19`）显示两节 7 号电池真实百分比；内置 **近场 (+14dB) / 标准 (+20dB) / 远场 (+26dB)** 三档实时增益调节与软限幅防破音。
- **4 大独立清爽工作区**：
  - **音频控制台**：2→1 汇聚声道、40 根极细声学微光柱、全屏自适应缩放与 3×2 系统权限自检。
  - **按键映射**：1:1 纯矢量 G9N9N 交互遥控器 + 15 键自由自定义（36 项内置编程/办公动作 + 原位录键二次确认）。
  - **长按扩展**：独立 2 列大卡片页为 8 枚功能键配置「短按 + 长按 0.38s」双功能，未配长按的按键保持 0ms 瞬发。
  - **自动场景**：监听 macOS 原生前台应用切换（零耗电），在 Cursor / VS Code / Antigravity / Xcode / 终端与浏览器 / 办公应用间自动无损切换独立键位档案，支持自由添加运行中应用。
- **极低常驻内存架构**：100% 原生 Swift（关闭窗口即释放 SwiftUI 视图树）+ 纯 C 自研 MIT 虚拟驱动（`G9N9N-Vibe Mic 2ch`，原生声明 USB 属性绕过豆包过滤），整包仅约 `2.5 MB`，零第三方依赖。

---

## ⚠️ 首次打开说明（免费开源 Ad-Hoc 签名）

本项目为免费开源软件，采用 **Ad-Hoc 签名**（未使用 Apple $99/年付费开发者公证账号）。从 GitHub Releases 下载 DMG 并将 `G9NVibe.app` 拖入「应用程序」后，首次打开时 macOS Gatekeeper 会提示 **「无法验证开发者」**，任选以下任意一种方式放行一次即可永久使用：

1. **图形界面放行（推荐）**：尝试打开一次看到弹窗后点「完成」，进入 **系统设置 → 隐私与安全性**，拉到最底部点击 **「仍要打开」** 并确认即可。
2. **终端一行放行（3 秒搞定）**：
   ```bash
   xattr -cr /Applications/G9NVibe.app
   ```

---

## 本地构建与自测

```bash
# 1. 运行 ATVV/ADPCM 协议与 22 项核心状态机自动化自测
./Scripts/run-self-tests.sh

# 2. 本地编译纯 C 驱动 + Release App + 单文件 DMG
./Scripts/build-dmg.sh

# 3. 编译 Apple Silicon + Intel 双架构 Universal 通用 DMG
BUILD_UNIVERSAL=1 ./Scripts/build-dmg.sh
```

## GitHub 自动发布 DMG 与官网部署

1. **仅按版本标签自动打包发布 DMG**：本仓库已内置 [`.github/workflows/release.yml`](.github/workflows/release.yml)。**平时普通 `git push` 提交代码不会触发打包**，只有推送 `v*` 版本标签（或手动点 Run workflow）时才会触发云端 macOS 自动跑 24 项自测、编译双架构 Universal 包并发布至 GitHub Releases：
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
   也可在 GitHub 仓库的 **Actions → Build & Release macOS DMG → Run workflow** 手动触发。
2. **产品介绍官网（GitHub Pages）**：仓库内置 [`docs/index.html`](docs/index.html)。进入 GitHub 仓库 **Settings → Pages**，将 Source 设为 **Deploy from a branch → `main` / `/docs`**，保存后 1 分钟即可通过 <https://zaoann8.github.io/G9N9NVibe/> 访问。

---

## 硬件边界说明

- **兼容版 G9N9N 遥控器（VID `0x18D1` / PID `0x9450`）**：全 15 键完整可用（14 枚 HID 按键 + 1 枚 BLE 语音键）。
- **Google 原装正版 G9N9N**：受其原厂固件限制，直连 macOS 时仅广播黑色语音键（BLE ATVV），其余 14 键不向 macOS 发送 HID 报文。
