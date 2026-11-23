import Foundation

enum VirtualDiskImageStore {
    enum StoreError: LocalizedError {
        case unsupportedCapacity
        case createFailed
        case invalidResult

        var errorDescription: String? {
            switch self {
            case .unsupportedCapacity: return "Choose a virtual disk capacity between 16 and 128 GiB."
            case .createFailed: return "The blank virtual disk could not be created in app storage."
            case .invalidResult: return "The created virtual disk did not have the requested size."
            }
        }
    }

    static func create(sizeGiB: Int) throws -> URL {
        guard [16, 32, 64, 128].contains(sizeGiB) else {
            throw StoreError.unsupportedCapacity
        }
        let capacity = UInt64(sizeGiB) * 1024 * 1024 * 1024
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AkatsubakiEmu/Disks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("VM-\(UUID().uuidString).raw")
        guard FileManager.default.createFile(atPath: url.path, contents: Data(),
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw StoreError.createFailed
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: capacity)
            try handle.synchronize()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, values.fileSize == Int(capacity) else {
                throw StoreError.invalidResult
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
