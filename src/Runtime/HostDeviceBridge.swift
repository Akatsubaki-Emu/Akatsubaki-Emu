import Foundation
import UIKit

/// Host-side device services available to an eventual guest transport adapter.
///
/// This deliberately separates device access from the CPU emulator. It is safe
/// to use from the iOS app now, but a guest cannot call these methods until a
/// real VM network/virtio-serial adapter is connected to this service.
final class HostDeviceBridge {
    static let shared = HostDeviceBridge()
    private init() {}
    private let maximumInMemoryTransferBytes = 64 * 1024 * 1024

    enum BridgeError: LocalizedError {
        case invalidPath
        case outsideSharedDirectory
        case unavailableDeviceInformation
        case fileTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidPath: return "The requested host path is invalid."
            case .outsideSharedDirectory: return "The requested file is outside the i-Steam shared directory."
            case .unavailableDeviceInformation: return "Host device information is unavailable."
            case .fileTooLarge: return "The shared file exceeds the 64 MiB transfer limit."
            }
        }
    }

    /// A user-visible shared directory that can be exposed to the guest through
    /// a future virtio-fs, 9p, or explicit file-transfer adapter.
    var sharedDirectoryURL: URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GuestShared", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    struct DeviceInfo: Codable {
        let systemName: String
        let systemVersion: String
        let model: String
        let machineIdentifier: String
        let lowPowerModeEnabled: Bool
    }

    func deviceInfo() -> DeviceInfo {
        let device = UIDevice.current
        return DeviceInfo(
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            model: device.model,
            machineIdentifier: Self.machineIdentifier(),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    /// Copies a guest-exported file into the host's i-Steam shared directory.
    /// The relative path is validated to prevent directory traversal.
    @discardableResult
    func receiveFile(from source: URL, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0 == "." || $0 == ".." }) else {
            throw BridgeError.invalidPath
        }

        let destination = try sharedFileURL(relativePath: relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ExternalDriveStore.shared.withAccess(to: source) { coordinatedSource in
            let sourceValues = try coordinatedSource.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            guard sourceValues.isRegularFile == true,
                  let sourceSize = sourceValues.fileSize,
                  sourceSize >= 0 else {
                throw BridgeError.invalidPath
            }
            guard sourceSize <= maximumInMemoryTransferBytes else {
                throw BridgeError.fileTooLarge
            }

            let fm = FileManager.default
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).receive")
            defer { try? fm.removeItem(at: temporary) }
            guard fm.createFile(atPath: temporary.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }

            let input = try FileHandle(forReadingFrom: coordinatedSource)
            defer { try? input.close() }
            var output: FileHandle? = try FileHandle(forWritingTo: temporary)
            defer { try? output?.close() }
            var copiedBytes = 0
            let maximumCopyBytes = maximumInMemoryTransferBytes + 1
            while copiedBytes < maximumCopyBytes {
                let remaining = maximumCopyBytes - copiedBytes
                let chunk = try input.read(upToCount: min(64 * 1024, remaining)) ?? Data()
                if chunk.isEmpty { break }
                try output?.write(contentsOf: chunk)
                copiedBytes += chunk.count
            }
            guard copiedBytes <= maximumInMemoryTransferBytes else {
                throw BridgeError.fileTooLarge
            }
            try output?.synchronize()
            try output?.close()
            output = nil

            // Verify the temporary file before replacing an existing destination.
            let copiedValues = try temporary.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            guard copiedValues.isRegularFile == true,
                  let copiedSize = copiedValues.fileSize,
                  copiedSize == copiedBytes else {
                throw BridgeError.invalidPath
            }

            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: destination)
            }
        }
        return destination
    }

    func readSharedFile(relativePath: String) throws -> Data {
        let url = try sharedFileURL(relativePath: relativePath)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
            throw BridgeError.invalidPath
        }
        guard size <= maximumInMemoryTransferBytes else { throw BridgeError.fileTooLarge }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        let maximumReadBytes = maximumInMemoryTransferBytes + 1
        while data.count < maximumReadBytes {
            let remaining = maximumReadBytes - data.count
            let chunk = try handle.read(upToCount: min(64 * 1024, remaining)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= maximumInMemoryTransferBytes else {
            throw BridgeError.fileTooLarge
        }
        return data
    }

    func writeSharedFile(_ data: Data, relativePath: String) throws {
        guard data.count <= maximumInMemoryTransferBytes else { throw BridgeError.fileTooLarge }
        let url = try sharedFileURL(relativePath: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func sharedFileURL(relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0 == "." || $0 == ".." }) else {
            throw BridgeError.invalidPath
        }
        let root = sharedDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        // standardizedFileURL removes dot segments but does not resolve a
        // symlinked parent. Resolve existing path components before accepting
        // reads/writes so a shared-directory symlink cannot escape the sandbox.
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(rootPrefix) else {
            throw BridgeError.outsideSharedDirectory
        }
        return resolved
    }

    private static func machineIdentifier() -> String {
        // UIDevice has no public hardware identifier. Report the model family
        // rather than reading private sysctl values or a serial number.
        return UIDevice.current.model
    }
}
