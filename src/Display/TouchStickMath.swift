import Foundation

struct TouchStickMovement {
    let offsetX: CGFloat
    let offsetY: CGFloat
    let normalizedX: CGFloat
    let normalizedY: CGFloat
}

struct TouchStickMath {
    private let radius: CGFloat
    private let radiusSquared: CGFloat
    private let inverseRadius: CGFloat

    init(radius: CGFloat) {
        let value = max(1, radius)
        self.radius = value
        radiusSquared = value * value
        inverseRadius = 1 / value
    }

    @inline(__always)
    func transform(dx: CGFloat, dy: CGFloat) -> TouchStickMovement {
        let distanceSquared = dx * dx + dy * dy
        let scale = distanceSquared <= radiusSquared ? 1 : radius / sqrt(distanceSquared)
        let offsetX = dx * scale
        let offsetY = dy * scale
        return TouchStickMovement(
            offsetX: offsetX,
            offsetY: offsetY,
            normalizedX: offsetX * inverseRadius,
            normalizedY: offsetY * inverseRadius
        )
    }
}
