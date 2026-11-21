import Foundation

final class EmulationLog {
    static let shared = EmulationLog()
    private let queue = DispatchQueue(label: "com.chantinlongx.iSteam.emulation-log")
    private let fm = FileManager.default
    private let maximumLogBytes: UInt64 = 5 * 1024 * 1024
    private let url: URL
    private let previousURL: URL
    private let timestampFormatter = ISO8601DateFormatter()
    private var fileHandle: FileHandle?
    private var currentLogBytes: UInt64 = 0

    private init() {
        let directory = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("emulation.log")
        previousURL = directory.appendingPathComponent("emulation.previous.log")
    }

    func write(_ message: String) {
        queue.async {
            let safeMessage = String(message.prefix(8192))
            let line = "[\(self.timestampFormatter.string(from: Date()))] \(safeMessage)\n"
            guard let data = line.data(using: .utf8) else { return }
            self.append(data)
        }
    }

    private func append(_ data: Data) {
        guard openLogIfNeeded() else { return }

        if currentLogBytes > maximumLogBytes - UInt64(data.count) {
            rotateLog()
            guard openLogIfNeeded() else { return }
        }

        do {
            try fileHandle?.write(contentsOf: data)
            currentLogBytes += UInt64(data.count)
        } catch {
            closeLog()
        }
    }

    private func openLogIfNeeded() -> Bool {
        if fileHandle != nil { return true }

        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else { return false }
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            currentLogBytes = try handle.seekToEnd()
            fileHandle = handle
            return true
        } catch {
            closeLog()
            return false
        }
    }

    private func rotateLog() {
        closeLog()
        do {
            if fm.fileExists(atPath: previousURL.path) {
                try fm.removeItem(at: previousURL)
            }
            try fm.moveItem(at: url, to: previousURL)
            currentLogBytes = 0
        } catch {
            currentLogBytes = 0
        }
    }

    private func closeLog() {
        try? fileHandle?.close()
        fileHandle = nil
        currentLogBytes = 0
    }
}
