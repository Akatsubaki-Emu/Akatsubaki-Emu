import Foundation

@main
struct TouchStickMathTests {
    static func main() {
        var checked = 0
        for radius: CGFloat in [1, 12, 32, 96] {
            let optimized = TouchStickMath(radius: radius)
            for xi in -200...200 {
                for yi in -200...200 {
                    let dx = CGFloat(xi) / 2
                    let dy = CGFloat(yi) / 2
                    let distanceSquared = dx * dx + dy * dy
                    let scale = distanceSquared <= radius * radius ? 1 : radius / sqrt(distanceSquared)
                    let offsetX = dx * scale
                    let offsetY = dy * scale
                    let actual = optimized.transform(dx: dx, dy: dy)
                    precondition(abs(offsetX - actual.offsetX) < 0.000001)
                    precondition(abs(offsetY - actual.offsetY) < 0.000001)
                    precondition(abs(offsetX / radius - actual.normalizedX) < 0.000001)
                    precondition(abs(offsetY / radius - actual.normalizedY) < 0.000001)
                    checked += 1
                }
            }
        }
        print("Touch stick transform equivalence passed: \(checked) vectors across four radii")
    }
}
