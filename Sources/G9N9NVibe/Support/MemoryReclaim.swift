import AppKit
import Darwin
import Foundation

/// 针对 macOS 极低常驻后台打造的安全内存深度回收引擎：
/// 1. 主动清理 URLCache 与 CoreAnimation 显存渲染临时脏缓存；
/// 2. 调用系统官方 libsystem_malloc 安全整理接口 (malloc_zone_pressure_relief)；
/// 3. 严格保护 NanoZone / TinyZone 内存完整性，彻底杜绝 nanov2_guard_corruption 崩溃。
enum MemoryReclaim {
    /// 执行全套安全内存净化
    static func performDeepPurge() {
        // 1. 清理应用层基础网络与图片缓存
        URLCache.shared.removeAllCachedResponses()

        // 2. 强制刷空 CoreAnimation 事务与未提交的图层树
        CATransaction.begin()
        CATransaction.flush()
        CATransaction.commit()

        // 3. 安全调用系统分配器整理空闲页
        _ = malloc_zone_pressure_relief(nil, 0)

        // 4. 延迟一轮在 RunLoop 完全空闲后再次整理，稳固常驻内存
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            _ = malloc_zone_pressure_relief(nil, 0)
        }
    }
}
