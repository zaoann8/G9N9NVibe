import Foundation

/// 固定容量 Float32 环形缓冲区（启动预分配，读写过程零堆内存分配，极致低内存且无碎片）
final class FloatRingBuffer {
    private var storage: [Float]
    private let capacity: Int
    private var readIndex = 0
    private var writeIndex = 0
    private(set) var count = 0

    init(capacity: Int = 32_768) {
        self.capacity = max(1024, capacity)
        self.storage = [Float](repeating: 0, count: self.capacity)
    }

    func reset() {
        readIndex = 0
        writeIndex = 0
        count = 0
    }

    /// 写入单个样本；缓冲区满时自动丢弃最旧样本保证实时性
    @inline(__always)
    func push(_ value: Float) {
        storage[writeIndex] = value
        writeIndex += 1
        if writeIndex == capacity { writeIndex = 0 }
        if count == capacity {
            readIndex += 1
            if readIndex == capacity { readIndex = 0 }
        } else {
            count += 1
        }
    }

    /// 弹出单个样本，空时返回 nil
    @inline(__always)
    func pop() -> Float? {
        guard count > 0 else { return nil }
        let val = storage[readIndex]
        readIndex += 1
        if readIndex == capacity { readIndex = 0 }
        count -= 1
        return val
    }

    /// 丢弃最旧的 n 个样本，用于控制最大缓冲延迟
    func dropOldest(_ n: Int) {
        let toDrop = min(n, count)
        guard toDrop > 0 else { return }
        readIndex = (readIndex + toDrop) % capacity
        count -= toDrop
    }
}
