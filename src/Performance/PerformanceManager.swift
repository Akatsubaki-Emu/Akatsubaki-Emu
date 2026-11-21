import Foundation
import UIKit
import Metal

final class PerformanceManager {
    static let shared = PerformanceManager()
    private init() {}

    var summary: String {
        let device = MTLCreateSystemDefaultDevice() == nil ? "No Metal device" : "Metal"
        return "\(device) • \(DisplayCapabilities.maximumFramesPerSecond)Hz display • target \(RuntimeSettings.shared.frameRate.value) FPS"
    }

    var detailedSummary: String {
        """
        Display maximum: \(DisplayCapabilities.maximumFramesPerSecond) Hz
        Selected target: \(RuntimeSettings.shared.frameRate.value) FPS
        GPU: \(MTLCreateSystemDefaultDevice() == nil ? "Unavailable" : "Metal")
        Translation cache: path-storage prototype; not connected to a translator
        Shader cache: directory scaffold; no shader compiler integration
        Frame pacing: CADisplayLink monitor prototype; not wired to QEMU scheduling
        """
    }
}
