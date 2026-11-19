# G9NVibe

> 把你的 Google Chromecast (`G9N9N`) 语音遥控器，变成 macOS 原生 **Vibe Coding 实体声控编程与效率控制器**。
>
> - **产品官网**：<https://zaoann8.github.io/G9N9NVibe/>
> - **下载最新版 DMG**：<https://github.com/zaoann8/G9N9NVibe/releases/latest>

---

## 🌟 为什么选择 G9NVibe？（核心优势）

### 1. 🚀 极致性能：8MB ~ 12MB 常驻内存奇迹
- **绝非 Electron / Python 包装**：100% 原生 Swift + 纯 C 自研 CoreAudio HAL 驱动，整包体积仅 **约 2.7 MB**，零第三方臃肿框架依赖。
- **CoreGraphics Canvas 批量高刷渲染**：声学电平微光柱采用单层 Canvas 批量极速绘制，支持 120Hz ProMotion 满血高刷且运行时 **0 堆对象分配**。
- **关窗主动退还系统脏页**：窗口关闭时不仅彻底销毁 SwiftUI 视图树，更主动通知 macOS 内核退还分配器脏页（`malloc_zone_pressure_relief`），日常后台无感常驻仅 **8MB ~ 12MB**！

### 2. 🎙️ 开箱即用 · 系统麦永不常驻接管
- **免驱动即用**：拖进「应用程序」立即以 MacBook 内置麦 / AirPods 工作；如需蓝牙近场语音，点击「一键启用」1 秒部署内置纯 C 虚拟驱动（随时可一键无痕卸载）。
- **智能随动双麦路由**：独创 **仅电脑麦 / 智能随动（推荐）/ 仅遥控器麦 / 双麦合并** 4 档路由与 **一键关闭双麦**。
- **真·按需采麦**：按键盘自动用电脑麦、按遥控器自动用遥控器麦。待机绝不常亮橙灯、绝不拖垮 AirPods 音质，退出程序瞬间自动无感还原系统默认麦克风。

### 3. ⌨️ G9N9N 人体工学与 Vibe Coding 专属效率
- **【语音键】置顶首行**：最常用的语音输入触发键排在映射列表第 1 行，打开即配。
- **15 键全自定义 + 8 键长按双功能**：
  - 15 枚物理按键支持 36 项 AI 编程专用前台动作（如 `⌘K` 行内编辑、`⌘L` 对话、`⌘↩` 采纳代码、切换终端等）与原位录键二次确认；
  - 8 枚功能键支持「短按 + 长按 0.38s」双功能（例如确认键短按发送、长按换行），未配长按的键保持 0ms 瞬发。
- **自动场景随动**：原生监听 macOS 前台窗口切换（零轮询零耗电），在 Cursor / VS Code / Antigravity / Xcode / 终端自动激活编码预设，切到浏览器或办公软件自动恢复日常预设。
- **硬件真实电量 & 3 档灵敏度**：原生读取蓝牙标准电池服务（`0x180F`）显示两节 7 号电池真实百分比；提供 **近场 (+14dB) / 标准 (+20dB) / 远场 (+26dB)** 三档实时 DSP 增益调节与软限幅防破音。

### 4. 🔄 原生静默覆盖更新（权限零丢失）
- **自动保留权限**：内置 GitHub Releases 校验，一键静默覆盖安装并重启，**100% 保留已授予的辅助功能与麦克风等全部 macOS 系统权限**，无需重新授权。
- **点击空白自动收起**：常驻菜单栏快速控制卡，点击屏幕任何应用或空白处毫秒级自动关闭 dismiss。

---

## 4 大独立清爽工作区

1. **音频控制台**：2→1 汇聚声道、40 根极细声学微光柱、标准 960×660 舒适视界、3×2 系统权限与硬件自检方阵。
2. **按键映射**：1:1 纯矢量 G9N9N 交互遥控器 + 语音键首位置顶 + 15 键自由自定义。
3. **长按扩展**：独立 2 列大卡片页为 8 枚功能键配置短按/长按双功能。
4. **自动场景**：随前台当前应用自动无损切换独立预设档案，支持自由添加运行中应用。

---

## ⚠️ 首次打开说明（免费开源 Ad-Hoc 签名）

本项目为免费开源软件，采用 **Ad-Hoc 签名**（未使用 Apple $99/年付费开发者公证账号）。从 GitHub Releases 下载 DMG 并将 `G9NVibe.app` 拖入「应用程序」后，首次打开时 macOS Gatekeeper 会提示 **「无法验证开发者」**，任选以下任意一种方式放行一次即可永久使用：

1. **图形界面放行（推荐）**：尝试打开一次看到弹窗后点「完成」，进入 **系统设置 → 隐私与安全性**，拉到最底部点击 **「仍要打开」** 并确认即可。
2. **终端一行放行（3 秒搞定）**：
   ```bash
   xattr -cr /Applications/G9NVibe.app
   ```

---

## 本地构建与全量自测

```bash
# 1. 运行 ATVV/ADPCM 协议与 25 项核心状态机全量自动化自测
./Scripts/run-self-tests.sh

# 2. 本地编译纯 C 驱动 + Release App + 单文件 DMG
./Scripts/build-dmg.sh

# 3. 编译 Apple Silicon + Intel 双架构 Universal 通用 DMG
BUILD_UNIVERSAL=1 ./Scripts/build-dmg.sh
```

## GitHub 自动发布 DMG 与官网部署

1. **仅按版本标签自动打包发布 DMG**：本仓库已内置 [`.github/workflows/release.yml`](.github/workflows/release.yml)。平时普通 `git push` 不会触发打包，只有推送 `v*` 版本标签（或手动点 Run workflow）时才会触发云端 macOS 自动跑 25 项自测、编译双架构 Universal 包并发布至 GitHub Releases：
   ```bash
   git tag v1.0.3
   git push origin v1.0.3
   ```
2. **产品介绍官网（GitHub Pages）**：仓库内置 [`docs/index.html`](docs/index.html)。进入 GitHub 仓库 **Settings → Pages**，将 Source 设为 **Deploy from a branch → `main` / `/docs`**，保存后即可通过 <https://zaoann8.github.io/G9N9NVibe/> 访问。

---

## 硬件边界说明

- **兼容版 G9N9N 遥控器（VID `0x18D1` / PID `0x9450`）**：全 15 键完整可用（14 枚 HID 按键 + 1 枚 BLE 语音键）。
- **Google 原装正版 G9N9N**：受其原厂固件限制，直连 macOS 时仅广播黑色语音键（BLE ATVV），其余 14 键不向 macOS 发送 HID 报文。
