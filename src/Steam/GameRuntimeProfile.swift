import Foundation

/// Portable per-game settings inspired by DroidDeck's game profiles.
/// These settings are metadata until a compatible guest runtime consumes them.
struct GameRuntimeProfile: Codable, Equatable, Identifiable {
    let id: UUID
    var gameID: UUID
    var displayName: String
    var launchArguments: [String]
    var environment: [String: String]
    var preferredResolutionWidth: Int
    var preferredResolutionHeight: Int
    var targetFPS: Int
    var memoryMB: Int
    var cpuCount: Int
    var controllerEnabled: Bool
    var showOnScreenControls: Bool
    var compatibilityNotes: String
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        gameID: UUID,
        displayName: String,
        launchArguments: [String] = [],
        environment: [String: String] = [:],
        preferredResolutionWidth: Int = 1280,
        preferredResolutionHeight: Int = 720,
        targetFPS: Int = 60,
        memoryMB: Int = 4096,
        cpuCount: Int = 4,
        controllerEnabled: Bool = true,
        showOnScreenControls: Bool = false,
        compatibilityNotes: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.gameID = gameID
        self.displayName = displayName
        self.launchArguments = launchArguments
        self.environment = environment
        self.preferredResolutionWidth = preferredResolutionWidth
        self.preferredResolutionHeight = preferredResolutionHeight
        self.targetFPS = targetFPS
        self.memoryMB = memoryMB
        self.cpuCount = cpuCount
        self.controllerEnabled = controllerEnabled
        self.showOnScreenControls = showOnScreenControls
        self.compatibilityNotes = compatibilityNotes
        self.updatedAt = updatedAt
    }

    func validate() throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayName.utf8.count <= 256, !displayName.contains("\0"),
              !compatibilityNotes.contains("\0") else {
            throw ProfileError.invalidName
        }
        guard (320...8192).contains(preferredResolutionWidth),
              (240...8192).contains(preferredResolutionHeight),
              UInt64(preferredResolutionWidth) * UInt64(preferredResolutionHeight) * 4 <= 64 * 1024 * 1024 else {
            throw ProfileError.invalidResolution
        }
        guard (24...120).contains(targetFPS) else { throw ProfileError.invalidFrameRate }
        guard (256...16384).contains(memoryMB) else { throw ProfileError.invalidMemory }
        guard (1...16).contains(cpuCount) else { throw ProfileError.invalidCPUCount }
        guard launchArguments.count <= 256,
              launchArguments.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }),
              environment.count <= 128,
              environment.keys.allSatisfy({ key in
                  let bytes = Array(key.utf8)
                  guard let first = bytes.first else { return false }
                  let validFirst = (UInt8(65)...UInt8(90)).contains(first) || (UInt8(97)...UInt8(122)).contains(first) || first == UInt8(95)
                  return validFirst && bytes.dropFirst().allSatisfy {
                      (UInt8(65)...UInt8(90)).contains($0) || (UInt8(97)...UInt8(122)).contains($0)
                          || (UInt8(48)...UInt8(57)).contains($0) || $0 == UInt8(95)
                  }
              }),
              environment.values.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }),
              compatibilityNotes.utf8.count <= 16_384 else {
            throw ProfileError.invalidEnvironment
        }
    }

    enum ProfileError: LocalizedError {
        case invalidName, invalidResolution, invalidFrameRate, invalidMemory, invalidCPUCount, invalidEnvironment, corruptStoredProfile
        var errorDescription: String? {
            switch self {
            case .invalidName: return "A game profile needs a name."
            case .invalidResolution: return "Resolution must be between 320×240 and 8192×8192 and fit the 64 MiB framebuffer limit."
            case .invalidFrameRate: return "Target FPS must be between 24 and 120."
            case .invalidMemory: return "Profile memory must be between 256 MB and 16384 MB."
            case .invalidCPUCount: return "Profile CPU count must be between 1 and 16."
            case .invalidEnvironment: return "Environment variable names or values contain invalid characters."
            case .corruptStoredProfile: return "The existing per-game profile is unreadable; it was preserved rather than overwritten."
            }
        }
    }
}

/// Atomic, app-sandboxed profile storage. Environment variables are stored as
/// data only; they are never evaluated as shell code.
final class GameRuntimeProfileStore {
    static let shared = GameRuntimeProfileStore()
    private let fm = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let directory: URL
    private let lock = NSLock()

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("GameProfiles", isDirectory: true)
    }

    private func ensureDirectory() throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    func save(_ profile: GameRuntimeProfile) throws {
        lock.lock()
        defer { lock.unlock() }
        try profile.validate()
        try ensureDirectory()
        var value = profile
        value.updatedAt = Date()
        let destination = url(for: value.gameID)
        if fm.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  let existingSize = values.fileSize, existingSize <= 1024 * 1024 else {
                throw GameRuntimeProfile.ProfileError.corruptStoredProfile
            }
            let existingData = try Data(contentsOf: destination)
            guard existingData.count <= 1024 * 1024,
                  let existing = try? decoder.decode(GameRuntimeProfile.self, from: existingData),
                  existing.gameID == value.gameID,
                  (try? existing.validate()) != nil else {
                throw GameRuntimeProfile.ProfileError.corruptStoredProfile
            }
        }
        let encoded = try encoder.encode(value)
        guard encoded.count <= 1024 * 1024 else {
            throw GameRuntimeProfile.ProfileError.invalidEnvironment
        }
        try encoded.write(to: destination, options: .atomic)
        EmulationLog.shared.write("Saved runtime profile for \(value.displayName)")
    }

    private func readProfile(at file: URL) -> GameRuntimeProfile? {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= 1024 * 1024,
              let data = try? Data(contentsOf: file), data.count <= 1024 * 1024,
              let profile = try? decoder.decode(GameRuntimeProfile.self, from: data),
              (try? profile.validate()) != nil,
              UUID(uuidString: file.deletingPathExtension().lastPathComponent) == profile.gameID else {
            return nil
        }
        return profile
    }

    @discardableResult
    func saveIfAbsent(_ profile: GameRuntimeProfile) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        try profile.validate()
        try ensureDirectory()
        let destination = url(for: profile.gameID)
        if fm.fileExists(atPath: destination.path) {
            guard readProfile(at: destination) != nil else {
                throw GameRuntimeProfile.ProfileError.corruptStoredProfile
            }
            return false
        }
        var value = profile
        value.updatedAt = Date()
        let encoded = try encoder.encode(value)
        guard encoded.count <= 1024 * 1024 else {
            throw GameRuntimeProfile.ProfileError.invalidEnvironment
        }
        try encoded.write(to: destination, options: .atomic)
        EmulationLog.shared.write("Imported runtime profile for \(value.displayName)")
        return true
    }

    func profile(for gameID: UUID) -> GameRuntimeProfile? {
        readProfile(at: url(for: gameID))
    }

    func existingProfileIDs(for gameIDs: Set<UUID>) throws -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        guard !gameIDs.isEmpty else { return [] }
        if gameIDs.count <= 64 {
            var existing = Set<UUID>()
            existing.reserveCapacity(gameIDs.count)
            for gameID in gameIDs {
                let file = url(for: gameID)
                if let profile = readProfile(at: file) {
                    existing.insert(profile.gameID)
                } else if fm.fileExists(atPath: file.path) {
                    throw GameRuntimeProfile.ProfileError.corruptStoredProfile
                }
            }
            return existing
        }

        let files = try profileFiles()
        var existing = Set<UUID>()
        existing.reserveCapacity(min(files.count, gameIDs.count))
        for file in files {
            guard let gameID = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  gameIDs.contains(gameID) else { continue }
            guard let profile = readProfile(at: file), profile.gameID == gameID else {
                throw GameRuntimeProfile.ProfileError.corruptStoredProfile
            }
            existing.insert(gameID)
        }
        return existing
    }

    func removeProfile(for gameID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let file = url(for: gameID)
        if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
    }

    private func profileFiles() throws -> [URL] {
        try ensureDirectory()
        return try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
    }

    func validatedProfiles() -> [GameRuntimeProfile]? {
        guard let files = try? profileFiles() else { return nil }
        var profiles: [GameRuntimeProfile] = []
        profiles.reserveCapacity(files.count)
        for file in files {
            guard let profile = readProfile(at: file) else { return nil }
            profiles.append(profile)
        }
        profiles.sort {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        return profiles
    }

    var hasUnreadableProfiles: Bool {
        guard let files = try? profileFiles() else { return true }
        return files.contains { readProfile(at: $0) == nil }
    }

    var allProfiles: [GameRuntimeProfile] {
        guard let files = try? profileFiles() else {
            EmulationLog.shared.write("Game profile directory is unavailable; refusing to export an incomplete library backup")
            return []
        }
        return files.compactMap { readProfile(at: $0) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}
