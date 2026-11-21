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
                  let validFirst = (65...90).contains(first) || (97...122).contains(first) || first == 95
                  return validFirst && bytes.dropFirst().allSatisfy {
                      (65...90).contains($0) || (97...122).contains($0)
                          || (48...57).contains($0) || $0 == 95
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
            case .invalidResolution: return "Resolution must be between 320×240 and 8192×8192."
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

    private var directory: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("GameProfiles", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    func save(_ profile: GameRuntimeProfile) throws {
        try profile.validate()
        var value = profile
        value.updatedAt = Date()
        let destination = url(for: value.gameID)
        if fm.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.fileSizeKey])
            guard let existingSize = values.fileSize, existingSize <= 1024 * 1024 else {
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

    func profile(for gameID: UUID) -> GameRuntimeProfile? {
        let profileURL = url(for: gameID)
        guard let values = try? profileURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size <= 1024 * 1024,
              let data = try? Data(contentsOf: profileURL),
              data.count <= 1024 * 1024,
              let value = try? decoder.decode(GameRuntimeProfile.self, from: data),
              (try? value.validate()) != nil else { return nil }
        return value
    }

    func removeProfile(for gameID: UUID) throws {
        let file = url(for: gameID)
        if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
    }

    private var profileFiles: [URL] {
        (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
    }

    var hasUnreadableProfiles: Bool {
        profileFiles.contains { file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize, size <= 1024 * 1024,
                  let data = try? Data(contentsOf: file), data.count <= 1024 * 1024,
                  let profile = try? decoder.decode(GameRuntimeProfile.self, from: data),
                  (try? profile.validate()) != nil else { return true }
            return false
        }
    }

    var allProfiles: [GameRuntimeProfile] {
        profileFiles.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize, size <= 1024 * 1024,
                  let data = try? Data(contentsOf: file), data.count <= 1024 * 1024,
                  let profile = try? decoder.decode(GameRuntimeProfile.self, from: data),
                  (try? profile.validate()) != nil else { return nil }
            return profile
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}
