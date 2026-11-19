import AppKit
import Darwin
import Foundation

/// 针对 macOS 极低常驻后台打造的内核级内存深度回收引擎：
/// 1. 主动通知分配器 libsystem_malloc 执行全局压降 (malloc_zone_pressure_relief)；
/// 2. 清理 CoreGraphics / CoreUI / Foundation / AppKit 内部渲染临时脏缓存；
/// 3. 通过 Darwin XNU 内核专用 MADV_FREE_REUSABLE 建议内核回收空闲页并即时从 Footprint 扣除。
enum MemoryReclaim {
    private static let MADV_FREE_REUSABLE_DARWIN: Int32 = 7

    /// 执行全套深度内存净化与脏页归还系统
    static func performDeepPurge() {
        // 1. 清理应用层基础缓存
        URLCache.shared.removeAllCachedResponses()

        // 2. 强制刷空 CoreAnimation 事务与未提交的图层树
        CATransaction.begin()
        CATransaction.flush()
        CATransaction.commit()

        // 3. 第一轮压降：强制分配器清空空闲链表 (malloc_zone_pressure_relief)
        _ = malloc_zone_pressure_relief(nil, 0)

        // 4. 第二轮延时压降：待上一帧 RunLoop 完全退出后归还残余堆块
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            _ = malloc_zone_pressure_relief(nil, 0)
            trimHeapPagesToKernel()
        }
    }

    /// 遍历当前进程的可写堆段，对未被活跃占用的页显式向内核发出 MADV_FREE_REUSABLE
    private static func trimHeapPagesToKernel() {
        var address: vm_address_t = 0
        var size: vm_size_t = 0
        var depth: natural_t = 0
        var info = vm_region_submap_info_64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_region_submap_info_64>.stride / MemoryLayout<natural_t>.stride)

        while true {
            let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { infoPtr in
                infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                    vm_region_recurse_64(mach_task_self_, &address, &size, &depth, intPtr, &count)
                }
            }
            guard kr == KERN_SUCCESS else { break }

            if info.is_submap == 0 {
                // 仅对用户态可读写堆块（非共享、非系统共享缓存代码段）做优化
                let isWritableUserHeap = (info.protection & VM_PROT_WRITE != 0) &&
                    (info.share_mode == UInt8(SM_COW) || info.share_mode == UInt8(SM_PRIVATE)) &&
                    info.user_tag == UInt32(VM_MEMORY_MALLOC)
                if isWritableUserHeap && size >= 65536 {
                    _ = madvise(UnsafeMutableRawPointer(bitPattern: address), Int(size), MADV_FREE_REUSABLE_DARWIN)
                }
                address += size
            } else {
                depth += 1
            }
        }
    }
}
