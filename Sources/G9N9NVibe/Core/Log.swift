import Foundation

/// 轻量日志系统：写入 ~/Library/Logs/G9N9N-Vibe/app.log，超过 2MB 自动轮转，防止长时间运行膨胀
enum AppLog {
    private static let lock = NSLock()
    private static var fileHandle: FileHandle?
    private static let maxLogSize: UInt64 = 2 * 1024 * 1024

    static let logDirectoryURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/G9N9N-Vibe", isDirectory: true)
    }()

    static let logFileURL: URL = {
        logDirectoryURL.appendingPathComponent("app.log")
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func setup() {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
        if let attrs = try? fm.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? UInt64,
           size > maxLogSize {
            let backup = logDirectoryURL.appendingPathComponent("app.prev.log")
            try? fm.removeItem(at: backup)
            try? fm.moveItem(at: logFileURL, to: backup)
        }
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        _ = try? fileHandle?.seekToEnd()
    }

    static func write(_ tag: String, _ message: String) {
        let line = "[\(dateFormatter.string(from: Date()))] [\(tag)] \(message)\n"
        #if DEBUG
        fputs(line, stdout)
        #endif
        lock.lock()
        defer { lock.unlock() }
        if let data = line.data(using: .utf8) {
            try? fileHandle?.write(contentsOf: data)
        }
    }
}
