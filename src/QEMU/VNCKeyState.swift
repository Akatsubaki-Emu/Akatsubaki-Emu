struct VNCKeyState {
    struct Event: Equatable {
        let keysym: UInt32
        let isDown: Bool
    }

    private static let movementKeys: [(mask: UInt8, keysym: UInt32)] = [
        (0x01, 0x41), (0x02, 0x44), (0x04, 0x57), (0x08, 0x53)
    ]

    private var keySources: [UInt32: Set<String>] = [:]
    private var movementSources: [String: UInt8] = [:]
    private(set) var pressedKeys = Set<UInt32>()

    static func movementMask(for x: Float, y: Float) -> UInt8 {
        var mask: UInt8 = 0
        if x < -0.25 { mask |= 0x01 }
        else if x > 0.25 { mask |= 0x02 }
        if y < -0.25 { mask |= 0x04 }
        else if y > 0.25 { mask |= 0x08 }
        return mask
    }

    mutating func setKey(_ keysym: UInt32, source: String, isDown: Bool) -> Event? {
        guard !source.isEmpty else { return nil }
        let wasPressed = pressedKeys.contains(keysym)
        if isDown {
            keySources[keysym, default: []].insert(source)
        } else if var sources = keySources[keysym] {
            sources.remove(source)
            if sources.isEmpty {
                keySources.removeValue(forKey: keysym)
            } else {
                keySources[keysym] = sources
            }
        }
        let shouldBePressed = keySources[keysym]?.isEmpty == false
            || movementMask & Self.movementMask(for: keysym) != 0
        guard shouldBePressed != wasPressed else { return nil }
        if shouldBePressed { pressedKeys.insert(keysym) }
        else { pressedKeys.remove(keysym) }
        return Event(keysym: keysym, isDown: shouldBePressed)
    }

    mutating func setMovement(_ mask: UInt8, source: String) -> [Event] {
        guard !source.isEmpty else { return [] }
        let previousMask = movementMask
        let normalizedMask = mask & 0x0f
        if normalizedMask == 0 {
            movementSources.removeValue(forKey: source)
        } else {
            movementSources[source] = normalizedMask
        }
        let changedMask = previousMask ^ movementMask
        var events: [Event] = []
        for movement in Self.movementKeys where changedMask & movement.mask != 0 {
            let wasPressed = pressedKeys.contains(movement.keysym)
            let shouldBePressed = movementMask & movement.mask != 0
                || keySources[movement.keysym]?.isEmpty == false
            guard shouldBePressed != wasPressed else { continue }
            if shouldBePressed { pressedKeys.insert(movement.keysym) }
            else { pressedKeys.remove(movement.keysym) }
            events.append(Event(keysym: movement.keysym, isDown: shouldBePressed))
        }
        return events
    }

    mutating func releaseAll() -> [Event] {
        let events = pressedKeys.sorted().map { Event(keysym: $0, isDown: false) }
        keySources.removeAll()
        movementSources.removeAll()
        pressedKeys.removeAll()
        return events
    }

    func isPressed(_ keysym: UInt32) -> Bool {
        pressedKeys.contains(keysym)
    }

    private var movementMask: UInt8 {
        movementSources.values.reduce(UInt8(0)) { $0 | $1 }
    }

    private static func movementMask(for keysym: UInt32) -> UInt8 {
        movementKeys.first(where: { $0.keysym == keysym })?.mask ?? 0
    }
}
