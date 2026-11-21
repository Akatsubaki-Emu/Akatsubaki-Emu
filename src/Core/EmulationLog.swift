import Foundation

final class EmulationLog {
    static let shared = EmulationLog()
    private let queue = DispatchQueue(label: "com.chantinlongx.iSteam.emulation-log")
    private let fm = FileManager.default
    private let maximumLogBytes = 5 * 1024 * 1024
    private let url: URL
    private let previousURL: URL
    private let timestampFormatter = ISO8601DateFormatter()

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
            if let attributes = try? self.fm.attributesOfItem(atPath: self.url.path),
               let size = attributes[.size] as? NSNumber,
               size.intValue >= self.maximumLogBytes {
                _ = try? self.fm.removeItem(at: self.previousURL)
                _ = try? self.fm.moveItem(at: self.url, to: self.previousURL)
            }
            if let handle = try? FileHandle(forWritingTo: self.url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: self.url)
            }
        }
    }
}
