import Foundation

private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@main
enum ControllerMappingNotificationTests {
    static func main() {
        let store = ControllerMappingStore.shared
        let counter = NotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: ControllerMappingStore.profileDidChangeNotification,
            object: nil,
            queue: nil
        ) { note in
            if note.object as? ControllerMappingStore === store { counter.increment() }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        var profile = store.profile
        profile.leftDeadzone = 0.2
        store.profile = profile
        precondition(counter.count == 1)
        precondition(store.profile.leftDeadzone == 0.2)

        store.reset()
        precondition(counter.count == 2)
        precondition(store.profile == .standard)

        let invalid = ControllerMappingProfile(
            buttonActions: [:], leftDeadzone: 0.9, rightDeadzone: 0.12,
            invertLookY: false, swapSticks: false
        )
        store.profile = invalid
        precondition(counter.count == 2)
        precondition(store.profile == .standard)
        print("Controller mapping notification tests passed")
    }
}
