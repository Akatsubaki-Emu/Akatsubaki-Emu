import Foundation

/// Starts the in-process QEMU runtime. The command preview is diagnostic only.
final class QEMUBackend {
    private let configuration: VMConfiguration
    private let builder: QEMUCommandBuilder
    private let runtime = QEMUNativeRuntime.shared
    private var sessionGeneration: UInt64?

    init(configuration: VMConfiguration) {
        self.configuration = configuration
        self.builder = QEMUCommandBuilder(configuration: configuration)
    }

    func commandPreview(diskImage: URL? = nil, writableDiskImage: URL? = nil, firmware: URL? = nil) -> String {
        let args = builder.arguments(diskImage: diskImage, writableDiskImage: writableDiskImage, firmware: firmware)
        return "qemu-system-\(configuration.architecture.rawValue) " + args.map(Self.quote).joined(separator: " ")
    }

    func start(diskImage: URL, writableDiskImage: URL? = nil, firmware: URL? = nil) throws {
        sessionGeneration = try runtime.start(configuration: configuration, diskImage: diskImage,
                                              writableDiskImage: writableDiskImage, firmware: firmware)
    }

    @discardableResult func reset() -> Bool {
        guard let sessionGeneration else { return false }
        return runtime.reset(sessionGeneration: sessionGeneration)
    }

    @discardableResult func stop() -> Bool {
        guard let sessionGeneration else { return true }
        return runtime.stop(sessionGeneration: sessionGeneration)
    }

    var isRunning: Bool { runtime.isRunning(sessionGeneration: sessionGeneration) }
    var isActive: Bool { runtime.isActive(sessionGeneration: sessionGeneration) }
    var lastError: String? { runtime.lastError(sessionGeneration: sessionGeneration) }

    private static func quote(_ value: String) -> String {
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
