import Foundation

struct GPUFrameRegion: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    func union(_ other: GPUFrameRegion) -> GPUFrameRegion {
        let left = min(x, other.x)
        let top = min(y, other.y)
        let right = max(x + width, other.x + other.width)
        let bottom = max(y + height, other.y + other.height)
        return GPUFrameRegion(x: left, y: top, width: right - left, height: bottom - top)
    }
}

protocol GPUBackend: AnyObject {
    var name: String { get }
    var isHardwareAccelerated: Bool { get }
    var width: Int { get }
    var height: Int { get }
    func start()
    func stop()
    func setSessionGeneration(_ generation: UInt64)
    func submit(frame: Data, width: Int, height: Int, dirtyRegion: GPUFrameRegion?, sessionGeneration: UInt64)
}
