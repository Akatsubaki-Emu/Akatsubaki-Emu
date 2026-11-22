#if !os(tvOS)
import Foundation
import CoreMotion

final class MotionInputManager {
    static let shared = MotionInputManager()
    private let motion = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "AkatsubakiEmu.MotionInput"
        queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private init() {}

    var isAvailable: Bool { motion.isDeviceMotionAvailable }
    var isRunning: Bool { motion.isDeviceMotionActive }
    private let stateLock = NSLock()
    private var cachedSensitivity: Double = {
        let stored = UserDefaults.standard.double(forKey: "iSteam.motionSensitivity")
        return stored > 0 ? min(stored, 5) : 1
    }()

    var sensitivity: Double {
        get { withStateLock { cachedSensitivity } }
        set {
            let normalized = min(max(newValue, 0.1), 5)
            withStateLock { cachedSensitivity = normalized }
            UserDefaults.standard.set(normalized, forKey: "iSteam.motionSensitivity")
        }
    }
    private var orientationHandler: ((Double, Double, Double) -> Void)?
    private var lookDeltaHandler: ((Double, Double) -> Void)?
    private var previousYaw: Double?
    private var previousPitch: Double?

    var onOrientation: ((Double, Double, Double) -> Void)? {
        get { withStateLock { orientationHandler } }
        set { withStateLock { orientationHandler = newValue } }
    }

    var onLookDelta: ((Double, Double) -> Void)? {
        get { withStateLock { lookDeltaHandler } }
        set { withStateLock { lookDeltaHandler = newValue } }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        withStateLock {
            previousYaw = nil
            previousPitch = nil
        }
        motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: queue) { [weak self] data, error in
            guard error == nil, let self, let data, self.motion.isDeviceMotionActive else { return }
            let yaw = data.attitude.yaw
            let pitch = data.attitude.pitch
            let roll = data.attitude.roll
            let callbacks = self.withStateLock { () -> (((Double, Double, Double) -> Void)?, ((Double, Double) -> Void)?, (Double, Double)?) in
                guard self.motion.isDeviceMotionActive else { return (nil, nil, nil) }
                var delta: (Double, Double)?
                if let oldYaw = self.previousYaw, let oldPitch = self.previousPitch {
                    var deltaYaw = yaw - oldYaw
                    if deltaYaw > .pi { deltaYaw -= 2 * .pi }
                    if deltaYaw < -.pi { deltaYaw += 2 * .pi }
                    let scale = self.cachedSensitivity
                    delta = (deltaYaw * scale, (pitch - oldPitch) * scale)
                }
                self.previousYaw = yaw
                self.previousPitch = pitch
                return (self.orientationHandler, self.lookDeltaHandler, delta)
            }
            callbacks.0?(yaw, pitch, roll)
            if let delta = callbacks.2 { callbacks.1?(delta.0, delta.1) }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        withStateLock {
            previousYaw = nil
            previousPitch = nil
        }
    }

    func recenter() {
        withStateLock {
            previousYaw = nil
            previousPitch = nil
        }
    }
}
#else
import Foundation

/// CoreMotion is unavailable on tvOS; retain the shared API as a no-op so the
/// common display controller can build for Apple TV without device-motion input.
final class MotionInputManager {
    static let shared = MotionInputManager()
    private init() {}

    var isAvailable: Bool { false }
    var isRunning: Bool { false }
    var sensitivity: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: "iSteam.motionSensitivity")
            return stored > 0 ? min(stored, 5) : 1
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 0.1), 5), forKey: "iSteam.motionSensitivity")
        }
    }
    var onOrientation: ((Double, Double, Double) -> Void)?
    var onLookDelta: ((Double, Double) -> Void)?
    func start() {}
    func stop() {}
    func recenter() {}
}
#endif
