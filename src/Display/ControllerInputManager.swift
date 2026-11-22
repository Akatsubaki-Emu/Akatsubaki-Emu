import Foundation
import GameController

final class ControllerInputManager {
    static let shared = ControllerInputManager()
    private init() {}

    var onMove: ((Float, Float, String) -> Void)?
    var onLook: ((Float, Float) -> Void)?
    var onButton: ((String, Bool, String) -> Void)?
    private var isStarted = false
    private var mappingProfileObserver: NSObjectProtocol?
    private let buttonActionLock = NSLock()
    private var activeButtonActions: [String: String] = [:]

    func start() {
        guard !isStarted else { return }
        isStarted = true
        NotificationCenter.default.addObserver(self, selector: #selector(connect(_:)), name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(disconnect(_:)), name: .GCControllerDidDisconnect, object: nil)
        mappingProfileObserver = NotificationCenter.default.addObserver(
            forName: ControllerMappingStore.profileDidChangeNotification,
            object: ControllerMappingStore.shared,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isStarted else { return }
            GCController.controllers().forEach(self.configure)
        }
        GCController.startWirelessControllerDiscovery {}
        GCController.controllers().forEach(configure)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        NotificationCenter.default.removeObserver(self)
        if let mappingProfileObserver {
            NotificationCenter.default.removeObserver(mappingProfileObserver)
            self.mappingProfileObserver = nil
        }
        GCController.stopWirelessControllerDiscovery()
        onLook?(0, 0)
        let profile = ControllerMappingStore.shared.profile
        for controller in GCController.controllers() {
            let source = sourceID(for: controller)
            onMove?(0, 0, source + ":left")
            onMove?(0, 0, source + ":right")
            guard let pad = controller.extendedGamepad else { continue }
            let buttons = buttonInputs(for: pad)
            for (_, name) in buttons {
                let buttonSource = source + ":button:" + name
                let action = mappedAction(for: name, source: buttonSource, pressed: false, profile: profile)
                onButton?(action, false, buttonSource)
            }
            detachHandlers(from: pad)
        }
    }

    @objc private func connect(_ note: Notification) {
        guard let controller = note.object as? GCController else { return }
        configure(controller)
    }

    @objc private func disconnect(_ note: Notification) {
        guard let controller = note.object as? GCController else { return }
        // A controller can disappear while a stick or button is held. Release
        // every guest input so the guest cannot remain stuck in movement/fire.
        let source = sourceID(for: controller)
        onMove?(0, 0, source + ":left")
        onMove?(0, 0, source + ":right")
        onLook?(0, 0)
        if let pad = controller.extendedGamepad {
            let profile = ControllerMappingStore.shared.profile
            let buttons = buttonInputs(for: pad)
            for (_, name) in buttons {
                let buttonSource = source + ":button:" + name
                let action = mappedAction(for: name, source: buttonSource, pressed: false, profile: profile)
                onButton?(action, false, buttonSource)
            }
            detachHandlers(from: pad)
        }
    }

    private func mappedAction(for name: String, source: String, pressed: Bool,
                              profile: ControllerMappingProfile) -> String {
        buttonActionLock.lock()
        defer { buttonActionLock.unlock() }
        if pressed {
            let action = profile.action(for: name)
            activeButtonActions[source] = action
            return action
        }
        return activeButtonActions.removeValue(forKey: source)
            ?? profile.action(for: name)
    }

    private func sourceID(for controller: GCController) -> String {
        "controller:" + String(describing: ObjectIdentifier(controller))
    }

    private func detachHandlers(from pad: GCExtendedGamepad) {
        pad.leftThumbstick.valueChangedHandler = nil
        pad.rightThumbstick.valueChangedHandler = nil
        for (button, _) in buttonInputs(for: pad) {
            button.valueChangedHandler = nil
        }
    }

    private func configure(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        let profile = ControllerMappingStore.shared.profile
        let leftDeadzone = ControllerDeadzone(profile.leftDeadzone)
        let rightDeadzone = ControllerDeadzone(profile.rightDeadzone)
        let source = sourceID(for: controller)
        let leftSource = source + ":left"
        let rightSource = source + ":right"
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            guard let self else { return }
            let point = leftDeadzone.apply(x: x, y: y)
            if profile.swapSticks { self.onLook?(point.0, point.1) }
            else { self.onMove?(point.0, point.1, leftSource) }
        }
        pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            guard let self else { return }
            var point = rightDeadzone.apply(x: x, y: y)
            if profile.invertLookY { point.1 = -point.1 }
            if profile.swapSticks { self.onMove?(point.0, point.1, rightSource) }
            else { self.onLook?(point.0, point.1) }
        }
        let buttons = buttonInputs(for: pad)
        for (button, name) in buttons {
            let buttonSource = source + ":button:" + name
            button.valueChangedHandler = { [weak self] _, _, pressed in
                guard let self else { return }
                let action = self.mappedAction(for: name, source: buttonSource,
                                               pressed: pressed, profile: profile)
                self.onButton?(action, pressed, buttonSource)
            }
        }
    }

    private func buttonInputs(for pad: GCExtendedGamepad) -> [(GCControllerButtonInput, String)] {
        var buttons: [(GCControllerButtonInput, String)] = [
            (pad.buttonA, "A"), (pad.buttonB, "B"), (pad.buttonX, "X"),
            (pad.buttonY, "Y"), (pad.buttonMenu, "Start"),
            (pad.leftShoulder, "LB"), (pad.rightShoulder, "RB"),
            (pad.leftTrigger, "LT"), (pad.rightTrigger, "RT"),
            (pad.dpad.up, "DPadUp"), (pad.dpad.down, "DPadDown"),
            (pad.dpad.left, "DPadLeft"), (pad.dpad.right, "DPadRight")
        ]
        if let leftThumbstickButton = pad.leftThumbstickButton {
            buttons.append((leftThumbstickButton, "L3"))
        }
        if let rightThumbstickButton = pad.rightThumbstickButton {
            buttons.append((rightThumbstickButton, "R3"))
        }
        return buttons
    }

}
