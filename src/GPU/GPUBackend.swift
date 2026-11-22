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
    func overlapsOrTouches(_ other: GPUFrameRegion) -> Bool {
        x <= other.x + other.width
            && other.x <= x + width
            && y <= other.y + other.height
            && other.y <= y + height
    }
}

struct GPUFrameRegionAccumulator {
    private(set) var regions: [GPUFrameRegion] = []
    private let maximumRegionCount: Int

    init(maximumRegionCount: Int = 32) {
        self.maximumRegionCount = max(1, maximumRegionCount)
    }

    mutating func add(_ region: GPUFrameRegion) {
        guard region.width > 0, region.height > 0 else { return }
        var merged = region
        var index = 0
        while index < regions.count {
            if regions[index].overlapsOrTouches(merged) {
                merged = merged.union(regions.remove(at: index))
                index = 0
            } else {
                index += 1
            }
        }
        regions.append(merged)
        guard regions.count > maximumRegionCount, var bounds = regions.first else { return }
        for region in regions.dropFirst() {
            bounds = bounds.union(region)
        }
        regions = [bounds]
    }
}

protocol GPUBackend: AnyObject {
    var name: String { get }
    var isHardwareAccelerated: Bool { get }
    var width: Int { get }
    var height: Int { get }
    func start()
    func stop()
    func submit(frame: Data, width: Int, height: Int, dirtyRegions: [GPUFrameRegion]?)
}
