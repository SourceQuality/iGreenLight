import Foundation
import os

/// Small logger that writes to the unified log and keeps a ring buffer for the in-app log view.
final class Log: @unchecked Sendable {
    static let shared = Log()
    private let logger = Logger(subsystem: "app.igreenlight", category: "app")
    private let lock = NSLock()
    private var lines: [String] = []
    private let fileHandle: FileHandle?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iGreenLight", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("iGreenLight.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
    }

    var logFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iGreenLight/iGreenLight.log")
    }

    func callAsFunction(_ tag: String, _ message: @autoclosure () -> String) {
        let text = "[\(tag)] \(message())"
        logger.log("\(text, privacy: .public)")
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
        let line = "\(stamp) \(text)"
        lock.lock()
        lines.append(line)
        if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
        fileHandle?.write((line + "\n").data(using: .utf8)!)
        lock.unlock()
        #if DEBUG
        print(line)
        #endif
    }

    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

let log = Log.shared
