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
        precondition(first.overlapsOrTouches(overlapping))
        precondition(!first.overlapsOrTouches(disjoint))

        var accumulator = GPUFrameRegionAccumulator(maximumRegionCount: 4)
        accumulator.add(first)
        accumulator.add(overlapping)
        accumulator.add(contained)
        precondition(accumulator.regions == [GPUFrameRegion(x: 10, y: 10, width: 35, height: 50)])
        accumulator.add(disjoint)
        precondition(accumulator.regions.count == 2)

        var bounded = GPUFrameRegionAccumulator(maximumRegionCount: 2)
        bounded.add(GPUFrameRegion(x: 0, y: 0, width: 2, height: 2))
        bounded.add(GPUFrameRegion(x: 100, y: 100, width: 2, height: 2))
        bounded.add(GPUFrameRegion(x: 200, y: 200, width: 2, height: 2))
        precondition(bounded.regions.count == 1)
        precondition(bounded.regions[0] == GPUFrameRegion(x: 0, y: 0, width: 202, height: 202))
        print("GPU dirty-region accumulator tests passed (overlap, adjacency, disjoint, containment, cap)")
    }
}
