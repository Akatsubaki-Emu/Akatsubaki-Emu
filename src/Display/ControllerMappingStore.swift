import Foundation

/// Persisted host-side controller preferences. These mappings are used by
/// ControllerInputManager; a guest still needs a transport adapter to consume
/// the resulting logical actions.
struct ControllerMappingProfile: Codable, Equatable {
    var buttonActions: [String: String]
    var leftDeadzone: Float
    var rightDeadzone: Float
    var invertLookY: Bool
    var swapSticks: Bool

    static let standard = ControllerMappingProfile(
        buttonActions: [
            "A": "confirm", "B": "cancel", "X": "west", "Y": "north",
            "Start": "menu", "LB": "previous", "RB": "next"
        ],
        leftDeadzone: 0.12,
        rightDeadzone: 0.12,
        invertLookY: false,
        swapSticks: false
    )

    func validate() throws {
        guard (0...0.8).contains(leftDeadzone),
              (0...0.8).contains(rightDeadzone),
              buttonActions.count <= 64,
              buttonActions.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 64 && !$0.value.isEmpty && $0.value.utf8.count <= 64 && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            throw MappingError.invalidProfile
        }
    }

    func action(for physicalButton: String) -> String {
        buttonActions[physicalButton] ?? physicalButton.lowercased()
    }

    enum MappingError: LocalizedError {
        case invalidProfile
        var errorDescription: String? { "The controller mapping contains invalid deadzone or button values." }
    }
}

struct ControllerDeadzone {
    private let deadzone: Float
    private let deadzoneSquared: Float
    private let inverseRange: Float

    init(_ deadzone: Float) {
        let normalized = min(max(deadzone, 0), 0.8)
        self.deadzone = normalized
        deadzoneSquared = normalized * normalized
        inverseRange = 1 / (1 - normalized)
    }

    @inline(__always)
    func apply(x: Float, y: Float) -> (Float, Float) {
        let magnitudeSquared = x * x + y * y
        guard magnitudeSquared > deadzoneSquared else { return (0, 0) }
        let magnitude = min(1, magnitudeSquared.squareRoot())
        let scaled = min(1, (magnitude - deadzone) * inverseRange)
        let factor = scaled / magnitude
        return (x * factor, y * factor)
    }
}

final class ControllerMappingStore {
    static let shared = ControllerMappingStore()
    static let profileDidChangeNotification = Notification.Name("iSteam.controllerMapping.profileDidChange")
    private let defaultsKey = "iSteam.controllerMapping.v1"
    private let lock = NSLock()
    private var cachedProfile: ControllerMappingProfile?
    private init() {}

    var profile: ControllerMappingProfile {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let cachedProfile { return cachedProfile }
            let value = loadProfile()
            cachedProfile = value
            return value
        }
        set {
            guard (try? newValue.validate()) != nil,
                  let data = try? JSONEncoder().encode(newValue) else { return }
            lock.lock()
            UserDefaults.standard.set(data, forKey: defaultsKey)
            cachedProfile = newValue
            lock.unlock()
            NotificationCenter.default.post(name: Self.profileDidChangeNotification, object: self)
        }
    }

    func reset() {
        lock.lock()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        cachedProfile = .standard
        lock.unlock()
        NotificationCenter.default.post(name: Self.profileDidChangeNotification, object: self)
    }

    private func loadProfile() -> ControllerMappingProfile {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey), data.count <= 64 * 1024,
              let value = try? JSONDecoder().decode(ControllerMappingProfile.self, from: data),
              (try? value.validate()) != nil else { return .standard }
        return value
    }
}
