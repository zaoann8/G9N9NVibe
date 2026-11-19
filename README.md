# G9NVibe

macOS 原生硬件桥接系统，将 Google Chromecast (G9N9N) 语音遥控器转化为专用实体声控与 Vibe Coding 效率控制器。

[产品官网](https://zaoann8.github.io/G9N9NVibe/) | [最新版本下载](https://github.com/zaoann8/G9N9NVibe/releases/latest)

---

## 项目概述

G9NVibe 是一款面向 macOS 平台的深度硬件桥接套件。通过自研纯 C CoreAudio 虚拟音频驱动、IOKit HID 报文捕获与 CoreBluetooth ATVV 协议栈，将 Google Chromecast 蓝牙遥控器（型号 G9N9N）重构为集近场语音输入、全键位映射、长按双功能与前台场景自动感知于一体的实体效率终端。

项目采用 100% 原生 Swift 与纯 C 架构开发，不依赖 Electron、Python 或 Chromium 等重型运行环境，保持轻量高效与系统级稳定性。

---

## 核心架构与技术特性

### 1. 智能随动双麦路由（按源选通）
- **独立虚拟音频驱动**：内置基于 CoreAudio HAL 架构的纯 C 驱动（G9N9NVibeMic.driver），随 App 一键加载或无痕卸载。
- **4 档选通策略**：
  - **智能随动（Smart By Source）**：键盘按键触发时选通 MacBook 内置麦克风；遥控器按键触发时选通 G9N9N 遥控器近场麦克风。
  - **仅电脑麦（Mac Only）**：完全由本机物理麦克风直通，不经过任何虚拟音频管线。
  - **仅遥控器麦（Remote Only）**：独占遥控器近场音频采集，待机时自动休眠。
  - **双麦合并（Dual Mix）**：两路音频按时间戳平滑混合，自动为 Mac 麦克风施加 120ms 对齐延迟以消除时差相位抵消。
- **按需采麦机制**：仅在激活语音录音时开启音频管道，平时待机绝不常驻接管系统默认麦克风，不亮系统橙色指示灯，不降低 AirPods 或蓝牙耳机音频采样率。退出进程瞬间系统自动还原物理麦克风。

### 2. 人体工学与 Vibe Coding 键位扩展
- **语音按键置顶调度**：最常用的语音触发键作为顶级配置项独立管理，支持单击、长按与双击触发模式。
- **15 枚物理按键全自定义**：
  - 覆盖 36 项内置高效动作，包括行内代码编辑（Command+K）、AI 对话激活（Command+L）、代码采纳（Command+Return）、终端唤醒及窗口管理。
  - 支持任意物理键位、修饰键（区分左右 Command / Option / Control / Shift）及组合键的原位录制。
- **8 枚功能键长按扩展**：方向键、确认键、返回键等支持短按瞬发（0ms）与长按延时（0.38s）双重动作绑定。
- **场景自动感知（Auto App Scene）**：通过 CoreGraphics 与 Workspace 事件监听前台应用切换，零轮询零空转。在 Cursor、VS Code、Xcode、Terminal 等开发环境中自动切入编程预设，切换至浏览器或办公软件时自动平滑还原通用预设。

### 3. 声学微光柱与高性能渲染引擎
- **CoreGraphics Canvas 批量极速绘制**：声学电平微光柱采用 40 根极细声学单元设计，在底层纯 2D Canvas 单图层中批量成形，运行时保持 0 堆对象分配。
- **120Hz ProMotion 满血高刷**：严格避开 Metal 显存池预分配开销，兼顾流畅度与低功耗。
- **关窗主动退还系统脏页**：窗口关闭常驻后台时，深度卸载 SwiftUI / AppKit 渲染树，主动向 macOS 内核退还分配器脏页（malloc_zone_pressure_relief），实现轻量无感常驻。

### 4. 硬件状态监控与原生升级维护
- **真实硬件电量显示**：基于 BLE 电池服务标准协议（0x180F / 0x2A19）实时读取 G9N9N 遥控器两节 AAA 电池硬件电量。
- **三档实时 DSP 增益控制**：提供近场（+14dB）、标准（+20dB）与远场（+26dB）三级线性增益与软限幅，针对不同持握距离优化收音灵敏度。
- **权限安全持久化升级**：基于 Designated Requirement 代码签名，升级或重新部署时完整保留辅助功能、麦克风与输入监控系统授权。

---

## 工作区功能模块

1. **音频控制台（Audio Console）**
   - 汇聚声道布局、双麦实时电平表、目标输入法路由配置；
   - 3×2 语义自检矩阵（输入法选通、声卡驱动状态、蓝牙遥控器连接、麦克风权限、辅助功能、输入监控）。
2. **按键映射（Key Mapping）**
   - 1:1 纯矢量手绘 G9N9N 遥控器，按键双向高亮联动；
   - 预设档案切换（Default / Code / Media）与单键动作配置。
3. **长按扩展（Long Press Extension）**
   - 8 枚核心物理键独立双栏长按动作设定。
4. **自动场景（Auto App Scene）**
   - 前台进程与键位预设映射规则列表，支持动态追加与启用管理。

---

## 硬件兼容性规范

- **兼容版 G9N9N 遥控器（VID 0x18D1 / PID 0x9450）**：支持全部 15 枚物理按键（14 枚 HID 按键 + 1 枚 BLE 语音键）。
- **Google 原装版 G9N9N 遥控器**：受原厂固件策略限制，直连 macOS 时仅黑色语音键（ATVV 协议）向主机广播音频数据，其余 14 枚按键固件默认锁定。

---

## 系统要求与首次运行配置

- **系统平台**：macOS 12.0 (Monterey) 或更高版本。
- **硬件架构**：Universal 2 二进制包，原生支持 Apple Silicon（M1–M4）及 Intel 处理器。
- **代码签名放行说明**：
  本项目为个人开源项目，采用 Ad-Hoc 本地签名。首次打开时 macOS Gatekeeper 若拦截提示未验证开发者，可通过以下任一方式放行：
  - 图形界面：打开系统设置 -> 隐私与安全性，滑至底部安全区域点击“仍要打开”。
  - 终端命令：
    ```bash
    xattr -cr /Applications/G9NVibe.app
    ```

---

## 本地编译与自动化测试

```bash
# 运行 ATVV/ADPCM 协议回归与 25 项状态机自测试
./Scripts/run-self-tests.sh

# 编译驱动、Release 程序并生成 DMG 安装包
./Scripts/build-dmg.sh

# 生成 Apple Silicon 与 Intel 双架构通用包
BUILD_UNIVERSAL=1 ./Scripts/build-dmg.sh
```

---

## 开源协议

本项目采用 MIT 许可证开源。
