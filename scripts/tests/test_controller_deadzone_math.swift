import Foundation

@main
struct ControllerDeadzoneMathTests {
    static func main() {
        let deadzones: [Float] = [0, 0.12, 0.5, 0.8]
        var checked = 0
        for deadzone in deadzones {
            let optimized = ControllerDeadzone(deadzone)
            for xIndex in -100...100 {
                for yIndex in -100...100 {
                    let x = Float(xIndex) / 100
                    let y = Float(yIndex) / 100
                    let expected = reference(x: x, y: y, deadzone: deadzone)
                    let actual = optimized.apply(x: x, y: y)
                    precondition(abs(expected.0 - actual.0) < 0.000001)
                    precondition(abs(expected.1 - actual.1) < 0.000001)
                    checked += 1
                }
            }
        }
        print("Controller deadzone equivalence passed: \(checked) vectors across four profiles")
    }

    private static func reference(x: Float, y: Float, deadzone: Float) -> (Float, Float) {
        let magnitudeSquared = x * x + y * y
        guard magnitudeSquared > deadzone * deadzone else { return (0, 0) }
        let magnitude = min(1, magnitudeSquared.squareRoot())
        let scaled = min(1, (magnitude - deadzone) / max(0.0001, 1 - deadzone))
        let factor = scaled / magnitude
        return (x * factor, y * factor)
    }
}
