@main
struct VNCKeyStateTests {
    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func main() {
        let space: UInt32 = 0x20
        let left: UInt32 = 0x41

        var state = VNCKeyState()
        expect(state.setKey(space, source: "keyboard:SPACE", isDown: true) == .init(keysym: space, isDown: true),
               "first key source must send key-down")
        expect(state.setKey(space, source: "controller:one:A", isDown: true) == nil,
               "second source must not send a duplicate key-down")
        expect(state.setKey(space, source: "keyboard:SPACE", isDown: false) == nil,
               "keyboard source release preserves a controller-held key")
        expect(state.isPressed(space), "key must remain held by the controller source")
        expect(state.setKey(space, source: "controller:one:A", isDown: false) == .init(keysym: space, isDown: false),
               "last key source must send key-up")

        expect(state.setKey(space, source: "controller:one:A", isDown: true) != nil,
               "first controller must acquire the key")
        expect(state.setKey(space, source: "controller:two:A", isDown: true) == nil,
               "second controller must share the held key")
        expect(state.setKey(space, source: "controller:one:A", isDown: false) == nil,
               "one controller release must preserve the other controller's key")
        expect(state.setKey(space, source: "controller:two:A", isDown: false) == .init(keysym: space, isDown: false),
               "last controller release must release the key")

        expect(state.setMovement(0x01, source: "touchgamepad").count == 1,
               "touch movement must press its direction")
        expect(state.setMovement(0x01, source: "touchgamepad").isEmpty,
               "unchanged movement samples must be ignored")
        expect(state.setMovement(0x01, source: "controller:one:left").isEmpty,
               "controller movement must share an already held direction")
        expect(state.setMovement(0, source: "touchgamepad").isEmpty,
               "movement source release preserves another source")
        expect(state.isPressed(left), "controller movement must remain active")
        expect(state.setMovement(0, source: "controller:one:left") == [
            .init(keysym: left, isDown: false)
        ], "last movement source must release its direction")

        expect(state.setMovement(0x01, source: "touchgamepad").count == 1,
               "movement can be pressed again after release")
        expect(state.setKey(left, source: "keyboard:A", isDown: true) == nil,
               "button source must share movement-held key")
        expect(state.setMovement(0, source: "touchgamepad").isEmpty,
               "movement release must preserve a held button")
        expect(state.setKey(left, source: "keyboard:A", isDown: false) == .init(keysym: left, isDown: false),
               "last button source must release after movement ends")

        expect(state.setKey(space, source: "keyboard:SPACE", isDown: false) == nil,
               "repeated key-up from an inactive source must be ignored")
        expect(state.setKey(space, source: "keyboard:SPACE", isDown: true) != nil,
               "key must be pressable after all sources release")
        expect(state.releaseAll() == [.init(keysym: space, isDown: false)],
               "releaseAll clears every source")
        expect(!state.isPressed(space), "releaseAll must leave no held keys")
        expect(state.setMovement(0x03, source: "touchgamepad") == [
            .init(keysym: 0x41, isDown: true), .init(keysym: 0x44, isDown: true)
        ], "diagonal movement must press both directions")
        expect(state.setMovement(0x01, source: "controller:one").isEmpty,
               "a second source holding left must not duplicate the press")
        expect(state.setMovement(0, source: "touchgamepad") == [
            .init(keysym: 0x44, isDown: false)
        ], "releasing one source must only release directions no longer held")
        expect(state.setMovement(0, source: "controller:one") == [
            .init(keysym: 0x41, isDown: false)
        ], "last source release must clear the cached direction")

        for (mask, keysym) in [(UInt8(0x01), UInt32(0x41)),
                               (UInt8(0x02), UInt32(0x44)),
                               (UInt8(0x04), UInt32(0x57)),
                               (UInt8(0x08), UInt32(0x53))] {
            var mappedState = VNCKeyState()
            expect(mappedState.setMovement(mask, source: "movement").count == 1,
                   "each movement direction must create one key-down")
            expect(mappedState.setKey(keysym, source: "keyboard", isDown: true) == nil,
                   "keyboard and movement sources must resolve to the same direction")
            expect(mappedState.setMovement(0, source: "movement").isEmpty,
                   "movement release must preserve a keyboard-held direction")
            expect(mappedState.setKey(keysym, source: "keyboard", isDown: false)
                   == .init(keysym: keysym, isDown: false),
                   "keyboard release must clear the final direction source")
        }

        print("VNC key-state tests passed")
    }
}
