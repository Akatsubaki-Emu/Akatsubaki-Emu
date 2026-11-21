import Foundation
import ImageIO

/// App-sandboxed cover-art cache. Artwork is copied from user-selected URLs;
/// remote URLs are not fetched implicitly and the original source is never modified.
final class GameArtworkStore {
    static let shared = GameArtworkStore()
    private let fm = FileManager.default
    private let maxBytes = 12 * 1024 * 1024
    private init() {}

    private var directory: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("GameArtwork", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    func importArtwork(from source: URL, for gameID: UUID) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maxBytes else {
            throw ArtworkError.invalidFile
        }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var imageData: Data?
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
            imageData = try? Data(contentsOf: readableURL, options: [.mappedIfSafe])
        }
        if let coordinationError { throw coordinationError }
        guard let data = imageData, data.count <= maxBytes,
              let image = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(image) > 0,
              CGImageSourceGetCount(image) <= 200,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              UInt64(width) * UInt64(height) <= 16 * 1024 * 1024,
              CGImageSourceCreateImageAtIndex(image, 0, nil) != nil,
              let type = CGImageSourceGetType(image) as String?,
              ["public.jpeg", "public.png", "public.heic", "public.webp", "com.compuserve.gif"].contains(type) else {
            throw ArtworkError.invalidImage
        }
        let ext: String
        switch type {
        case "public.jpeg": ext = "jpg"
        case "public.png": ext = "png"
        case "public.heic": ext = "heic"
        case "public.webp": ext = "webp"
        default: ext = "gif"
        }
        let destination = directory.appendingPathComponent(gameID.uuidString).appendingPathExtension(ext)
        try data.write(to: destination, options: .atomic)
        // Keep one canonical artwork file per game. Otherwise changing format
        // (for example PNG to JPEG) leaves an older file that may be selected
        // unpredictably by artworkURL(for:).
        let existing = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in existing where file.deletingPathExtension().lastPathComponent == gameID.uuidString
            && file != destination {
            try? fm.removeItem(at: file)
        }
        EmulationLog.shared.write("Cached cover artwork for game \(gameID.uuidString)")
        return destination
    }

    func artworkURL(for gameID: UUID) -> URL? {
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files.filter { $0.deletingPathExtension().lastPathComponent == gameID.uuidString }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }.first
    }

    func removeArtwork(for gameID: UUID) throws {
        guard fm.fileExists(atPath: directory.path) else { return }
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.deletingPathExtension().lastPathComponent == gameID.uuidString }
        for file in files { try fm.removeItem(at: file) }
    }

    enum ArtworkError: LocalizedError {
        case invalidFile, invalidImage
        var errorDescription: String? {
            switch self {
            case .invalidFile: return "Artwork must be a regular file no larger than 12 MB."
            case .invalidImage: return "The selected file is not a supported, readable image."
            }
        }
    }
}
