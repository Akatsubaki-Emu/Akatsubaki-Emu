import Foundation

@main
struct EmulationLogObserverTests {
    static func main() {
        let marker = "[guest stdout] observer-smoke-\(UUID().uuidString)"
        let delivered = DispatchSemaphore(value: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: .emulationLogDidWrite,
            object: nil,
            queue: nil
        ) { notification in
            guard let message = notification.userInfo?["message"] as? String,
                  message == marker else { return }
            delivered.signal()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        EmulationLog.shared.write(marker)
        precondition(delivered.wait(timeout: .now() + 5) == .success,
                     "Guest output notification was not delivered")
        print("Emulation log observer delivery passed")
    }
}
