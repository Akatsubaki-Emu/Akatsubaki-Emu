import Foundation

@main
struct GPUFrameRegionTests {
    static func main() {
        let first = GPUFrameRegion(x: 10, y: 20, width: 30, height: 40)
        let overlapping = GPUFrameRegion(x: 25, y: 10, width: 20, height: 30)
        precondition(first.union(overlapping) == GPUFrameRegion(x: 10, y: 10, width: 35, height: 50))
        let disjoint = GPUFrameRegion(x: 100, y: 120, width: 8, height: 9)
        precondition(first.union(disjoint) == GPUFrameRegion(x: 10, y: 20, width: 98, height: 109))
        let contained = GPUFrameRegion(x: 15, y: 25, width: 5, height: 6)
        precondition(first.union(contained) == first)
        print("GPU dirty-region union tests passed (overlap, disjoint, containment)")
    }
}
