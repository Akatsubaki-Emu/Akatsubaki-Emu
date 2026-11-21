import Foundation
import UIKit

final class CrashLogger {
    static let shared = CrashLogger()

    private let queue = DispatchQueue(label: "com.akatsubakiemu.crashlog")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let fileManager = FileManager.default
    private let maximumLogBytes = 5 * 1024 * 1024

    private init() {
        queue.setSpecific(key: queueKey, value: 1)
    }

    private var directory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
    }

    var latestLogURL: URL {
        directory.appendingPathComponent("latest-crash.log")
    }

    func install() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        NSSetUncaughtExceptionHandler { exception in
            CrashLogger.shared.record(
                type: "NSException",
                reason: exception.reason ?? "Unknown exception",
                details: exception.callStackSymbols.joined(separator: "\n")
            )
        }
        write("Akatsubaki Emu started — \(Date())")
    }

    func write(_ message: String) {
        queue.async {
            self.appendLogLine(message)
        }
    }

    private func appendLogLine(_ message: String) {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeMessage = String(message.prefix(8192))
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(safeMessage)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let attributes = try? fileManager.attributesOfItem(atPath: latestLogURL.path),
           let size = attributes[.size] as? NSNumber,
           size.int64Value >= Int64(maximumLogBytes) {
            rotateLatestLog()
        }

        if let handle = try? FileHandle(forWritingTo: latestLogURL) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
            }
        } else {
            try? data.write(to: latestLogURL, options: .atomic)
        }
    }

    private func rotateLatestLog() {
        let previous = directory.appendingPathComponent("previous-crash.log")
        try? fileManager.removeItem(at: previous)
        if fileManager.fileExists(atPath: latestLogURL.path) {
            try? fileManager.moveItem(at: latestLogURL, to: previous)
        }
    }

    private func performSynchronouslyOnQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    func record(type: String, reason: String, details: String) {
        let report = """
        ===== Akatsubaki Emu Crash =====
        Date: \(ISO8601DateFormatter().string(from: Date()))
        Type: \(String(type.prefix(128)))
        Reason: \(String(reason.prefix(4096)))

        \(String(details.prefix(500_000)))

        Device: \(UIDevice.current.model)
        System: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        Bundle: \(Bundle.main.bundleIdentifier ?? "unknown")
        ================================
        """

        performSynchronouslyOnQueue {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            rotateLatestLog()
            guard let data = report.data(using: .utf8), data.count <= maximumLogBytes else { return }
            try? data.write(to: latestLogURL, options: .atomic)
        }
    }

    func clear() {
        queue.async {
            let previous = self.directory.appendingPathComponent("previous-crash.log")
            try? self.fileManager.removeItem(at: self.latestLogURL)
            try? self.fileManager.removeItem(at: previous)
        }
    }
}
