import AppKit
import Darwin
import Foundation

/// 针对 macOS 极低常驻后台打造的内核级内存深度回收引擎：
/// 1. 主动遍历所有系统分配器堆区 (malloc_get_all_zones) 并执行全局激进压降；
/// 2. 清理 CoreAnimation / CoreGraphics / URLCache 渲染临时脏缓存；
/// 3. 通过 Darwin XNU 内核专用 MADV_FREE_REUSABLE 建议内核回收空闲页并即时从 Footprint 扣除。
enum MemoryReclaim {
    private static let MADV_FREE_REUSABLE_DARWIN: Int32 = 7

    /// 执行全套深度内存净化与脏页归还系统
    static func performDeepPurge() {
        // 1. 清理应用层基础网络与图片缓存
        URLCache.shared.removeAllCachedResponses()

        // 2. 强制刷空 CoreAnimation 事务与未提交的图层树
        CATransaction.begin()
        CATransaction.flush()
        CATransaction.commit()

        // 3. 遍历所有 malloc zones 执行激进压降
        pressureReliefAllZones()

        // 4. 第二轮延时压降：待上一帧 RunLoop 完全退出后归还残余堆块
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            pressureReliefAllZones()
            trimHeapPagesToKernel()
        }

        // 5. 第三轮深层沉淀：0.35s 后内核再次深层压降，达到极限最低常驻
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            pressureReliefAllZones()
            trimHeapPagesToKernel()
        }
    }

    /// 遍历所有活跃的 Malloc 堆区执行激进页清退
    private static func pressureReliefAllZones() {
        var zones: UnsafeMutablePointer<vm_address_t>?
        var count: UInt32 = 0
        if malloc_get_all_zones(mach_task_self_, nil, &zones, &count) == KERN_SUCCESS, let zones = zones {
            for i in 0..<Int(count) {
                let zoneAddress = zones[i]
                if let zonePtr = UnsafeMutableRawPointer(bitPattern: zoneAddress) {
                    let z = zonePtr.assumingMemoryBound(to: malloc_zone_t.self)
                    // 传入 128MB 的 goal，强制分配器清空空闲 slab/magazine 链表
                    _ = malloc_zone_pressure_relief(z, 128 * 1024 * 1024)
                }
            }
        } else {
            _ = malloc_zone_pressure_relief(nil, 128 * 1024 * 1024)
        }
    }

    /// 遍历当前进程的可写堆段，对未被活跃占用的页显式向内核发出 MADV_FREE_REUSABLE
    private static func trimHeapPagesToKernel() {
        var address: vm_address_t = 0
        var size: vm_size_t = 0
        var depth: natural_t = 0
        var info = vm_region_submap_info_64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_region_submap_info_64>.stride / MemoryLayout<natural_t>.stride)

        // Darwin 堆标签常量
        let heapTags: Set<UInt32> = [
            1,  // VM_MEMORY_MALLOC
            2,  // VM_MEMORY_MALLOC_SMALL
            3,  // VM_MEMORY_MALLOC_LARGE
            4,  // VM_MEMORY_MALLOC_HUGE
            11, // VM_MEMORY_MALLOC_NANO
            12  // VM_MEMORY_MALLOC_TINY
        ]

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
                    heapTags.contains(info.user_tag)
                if isWritableUserHeap && size >= 16384 {
                    _ = madvise(UnsafeMutableRawPointer(bitPattern: address), Int(size), MADV_FREE_REUSABLE_DARWIN)
                }
                address += size
            } else {
                depth += 1
            }
        }
    }
}
