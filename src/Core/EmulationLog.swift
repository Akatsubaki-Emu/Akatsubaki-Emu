import Foundation

final class EmulationLog {
    static let shared = EmulationLog()
    private let queue = DispatchQueue(label: "com.chantinlongx.iSteam.emulation-log")
    private let fm = FileManager.default
    private let maximumLogBytes = 5 * 1024 * 1024
    private var url: URL {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("emulation.log")
    }
    private init() {}

    func write(_ message: String) {
        queue.async {
            let safeMessage = String(message.prefix(8192))
            let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(safeMessage)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let attributes = try? self.fm.attributesOfItem(atPath: self.url.path),
               let size = attributes[.size] as? NSNumber,
               size.intValue >= self.maximumLogBytes {
                let previous = self.url.deletingLastPathComponent().appendingPathComponent("emulation.previous.log")
                try? self.fm.removeItem(at: previous)
                try? self.fm.moveItem(at: self.url, to: previous)
            }
            if let handle = try? FileHandle(forWritingTo: self.url) {
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: self.url)
            }
        }
    }
}
