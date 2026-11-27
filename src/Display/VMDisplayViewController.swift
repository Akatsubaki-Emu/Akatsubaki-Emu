import UIKit
import GameController

final class VMDisplayViewController: UIViewController {
    private let gpu: MetalGPUBackend
    private let virtioGPU: VirtIOGPU
    private let engine: VMEngine
    private let configuration: VMConfiguration
    private let vncClient = QEMUVNCClient()
    private let diskImage: URL
    private let writableDiskImage: URL?
    private let status = UILabel()
    private var gamepad: TouchGamepadView?
    private let vrSettings = VRSettings.shared
    private var keyboardPanel: KeyboardOverlayView?
    private let keyboardToggle = UIButton(type: .system)
    private let pointerLeftClick = UIButton(type: .system)
    private let pointerRightClick = UIButton(type: .system)
    private let functionKeyBar = UIStackView()
    private var keyboardObservers: [NSObjectProtocol] = []
    private var hardwareKeySources: [Int: (key: String, source: String)] = [:]
    private var lastMotionStatusUpdate: TimeInterval = 0
    private var lastReportedGuestFrameWidth = 0
    private var lastReportedGuestFrameHeight = 0
    private var engineStartRequested = false
    private var startupFlowStarted = false

    init(configuration: VMConfiguration, diskImage: URL, writableDiskImage: URL? = nil) {
        self.configuration = configuration
        self.diskImage = diskImage
        self.writableDiskImage = writableDiskImage
        let backend = MetalGPUBackend(width: configuration.displayWidth, height: configuration.displayHeight, frameRate: configuration.displayFPS)
        self.gpu = backend
        self.virtioGPU = VirtIOGPU(backend: backend)
        self.engine = VMEngine(configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        title = configuration.name
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var canBecomeFirstResponder: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Power Off", style: .plain, target: self, action: #selector(requestGuestPowerDown)
        )
        gpu.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gpu.view)
        status.translatesAutoresizingMaskIntoConstraints = false
        status.textColor = .white
        status.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        status.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        status.text = "\(configuration.displayWidth) × \(configuration.displayHeight) • \(configuration.displayFPS) FPS target • Metal"
        status.textAlignment = .center
        status.layer.cornerRadius = 8
        status.clipsToBounds = true
        view.addSubview(status)
        NSLayoutConstraint.activate([
            gpu.view.topAnchor.constraint(equalTo: view.topAnchor),
            gpu.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            gpu.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gpu.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            status.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            status.heightAnchor.constraint(equalToConstant: 30)
        ])
        if vrSettings.mode == .cardboard { applyCardboardLayout() }
        if vrSettings.touchGamepadEnabled { addTouchGamepad() }
        addKeyboardControls()
        configureControllerInput()
        configureMotionInput()
        engine.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .starting:
                self.status.text = "Starting QEMU • waiting for guest display"
            case .running:
                if !self.vncClient.isConnected {
                    self.status.text = "QEMU active • waiting for guest display"
                }
            case .stopping:
                self.status.text = "Stopping virtual machine…"
                self.releaseGuestInputs()
                self.vncClient.stop()
            case .stopped:
                self.status.text = "Guest session is stopped or paused. Start again to launch or resume the configured VM."
                self.releaseGuestInputs()
                self.vncClient.stop()
            case .failed(let message):
                self.status.text = "VM failed • \(message)"
                self.releaseGuestInputs()
                self.vncClient.stop()
            }
        }
        virtioGPU.start()
        vncClient.onSessionGenerationChanged = { [weak self] generation in
            guard let self else { return }
            self.virtioGPU.setSessionGeneration(generation)
            DispatchQueue.main.async { [weak self] in
                self?.lastReportedGuestFrameWidth = 0
                self?.lastReportedGuestFrameHeight = 0
            }
        }
        vncClient.onFrame = { [weak self] generation, data, width, height, dirtyRegion in
            guard let self else { return }
            self.virtioGPU.submit(.updateFramebuffer(data, width: width, height: height,
                dirtyRegion: dirtyRegion, sessionGeneration: generation))
            guard self.lastReportedGuestFrameWidth != width
                || self.lastReportedGuestFrameHeight != height else { return }
            self.lastReportedGuestFrameWidth = width
            self.lastReportedGuestFrameHeight = height
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if case .failed = self.engine.state { return }
                self.status.text = "\(width) × \(height) guest • \(self.configuration.displayWidth) × \(self.configuration.displayHeight) target • Metal"
            }
        }
        vncClient.onStatus = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                // Preserve the actual engine failure instead of replacing it with
                // the VNC client's expected connection-retry message.
                if case .failed = self.engine.state { return }
                self.status.text = message
                if message.contains("unavailable") {
                    EmulationLog.shared.write(message)
                }
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if keyboardObservers.isEmpty { registerKeyboardNotifications() }
        refreshHardwareKeyboardState()
        becomeFirstResponder()
        guard !startupFlowStarted else { return }
        startupFlowStarted = true
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if configuration.accelerator == .jit {
            guard JITCoordinator.shared.isQEMUProtocolAvailable else {
                startTCIFallbackIfAllowed(reason: JITCoordinator.shared.unavailableReason)
                return
            }
            if !JITCoordinator.shared.isQEMUJITReady {
                status.text = "Waiting for JIT • preparing LocalDevVPN and StikDebug"
                JITCoordinator.shared.requestJIT(from: self, onFailure: { [weak self] message in
                    DispatchQueue.main.async {
                        self?.startTCIFallbackIfAllowed(reason: message)
                    }
                }) { [weak self] in
                    DispatchQueue.main.async {
                        self?.startEngine()
                    }
                }
            } else {
                startEngine()
            }
        } else {
            status.text = "Starting the no-JIT QEMU TCI interpreter"
            startEngine()
        }
        #else
        startEngine()
        #endif
    }

    private func startTCIFallbackIfAllowed(reason: String) {
        guard RuntimeSettings.shared.acceleration.allowsTCIFallback else {
            status.text = "QEMU JIT unavailable • \(reason)"
            EmulationLog.shared.write("QEMU JIT unavailable and automatic TCI fallback is disabled: \(reason)")
            return
        }

        switch QEMURuntimeStatus.inspect(requiresJIT: false) {
        case .ready:
            status.text = "JIT unavailable • starting no-JIT QEMU TCI interpreter"
            EmulationLog.shared.write("QEMU JIT unavailable; Automatic mode is falling back to TCI: \(reason)")
            startEngine()
        case .unavailable(let tciReason):
            status.text = "QEMU JIT unavailable • \(reason). TCI fallback unavailable • \(tciReason)"
            EmulationLog.shared.write("QEMU TCI fallback unavailable: \(tciReason)")
        }
    }

    private func startEngine() {
        guard !engineStartRequested else { return }
        engineStartRequested = true
        status.text = "Starting QEMU • waiting for guest display"
        engine.start(diskImage: diskImage, writableDiskImage: writableDiskImage)
        if case .failed(let message) = engine.state {
            status.text = "VM failed • \(message)"
            EmulationLog.shared.write("Display launch failed: \(message)")
        } else {
            vncClient.start()
        }
    }

    @objc private func requestGuestPowerDown() {
        guard engine.requestGuestPowerDown() else {
            status.text = "Power off unavailable • QEMU guest is not running"
            return
        }
        status.text = "ACPI power button sent • waiting for guest OS shutdown"
    }

    private func applyCardboardLayout() {
        // Layout scaffold only; true stereo needs independent per-eye guest rendering.
        gpu.view.transform = CGAffineTransform(scaleX: 0.5, y: 1)
        gpu.view.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        gpu.view.frame = CGRect(x: 0, y: 0, width: view.bounds.width * 2, height: view.bounds.height)
        gpu.view.contentMode = .scaleAspectFit
        status.text = "CARDBOARD • motion look prototype"
    }

    private func addKeyboardControls() {
        keyboardToggle.translatesAutoresizingMaskIntoConstraints = false
        keyboardToggle.setTitle("⌨ Keyboard", for: .normal)
        var keyboardConfiguration = UIButton.Configuration.filled()
        keyboardConfiguration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.78)
        keyboardConfiguration.baseForegroundColor = .white
        keyboardConfiguration.cornerStyle = .medium
        keyboardConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        keyboardConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 13, weight: .semibold)
            return outgoing
        }
        keyboardToggle.configuration = keyboardConfiguration
        keyboardToggle.addTarget(self, action: #selector(toggleTouchKeyboard), for: .touchUpInside)
        view.addSubview(keyboardToggle)
        configurePointerClickButton(pointerLeftClick, title: "L Click", buttonMask: 0x01)
        configurePointerClickButton(pointerRightClick, title: "R Click", buttonMask: 0x04)

        functionKeyBar.translatesAutoresizingMaskIntoConstraints = false
        functionKeyBar.axis = .horizontal
        functionKeyBar.alignment = .fill
        functionKeyBar.distribution = .fillEqually
        functionKeyBar.spacing = 4
        functionKeyBar.backgroundColor = UIColor.black.withAlphaComponent(0.84)
        for number in 1...12 {
            let key = "F\(number)"
            let button = UIButton(type: .system)
            button.setTitle(key, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 11, weight: .bold)
            button.setTitleColor(.white, for: .normal)
            button.backgroundColor = UIColor(white: 0.24, alpha: 1)
            button.layer.cornerRadius = 5
            button.addAction(UIAction { [weak self] _ in self?.emitKeyboardKey(key) }, for: .touchUpInside)
            functionKeyBar.addArrangedSubview(button)
        }
        view.addSubview(functionKeyBar)
        functionKeyBar.isHidden = true

        let panel = KeyboardOverlayView { [weak self] key in self?.emitKeyboardKey(key) }
        panel.onKeyEvent = { [weak self] key, down in self?.vncClient.sendButton(key, down: down, source: "keyboard") }
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        view.addSubview(panel)
        keyboardPanel = panel

        NSLayoutConstraint.activate([
            keyboardToggle.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            keyboardToggle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            pointerLeftClick.topAnchor.constraint(equalTo: keyboardToggle.topAnchor),
            pointerLeftClick.trailingAnchor.constraint(equalTo: keyboardToggle.leadingAnchor, constant: -6),
            pointerLeftClick.widthAnchor.constraint(equalToConstant: 64),
            pointerRightClick.topAnchor.constraint(equalTo: keyboardToggle.topAnchor),
            pointerRightClick.trailingAnchor.constraint(equalTo: pointerLeftClick.leadingAnchor, constant: -6),
            pointerRightClick.widthAnchor.constraint(equalToConstant: 64),
            functionKeyBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            functionKeyBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            functionKeyBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            functionKeyBar.heightAnchor.constraint(equalToConstant: 38),
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            panel.heightAnchor.constraint(equalToConstant: 238)
        ])
    }

    private func configurePointerClickButton(_ button: UIButton, title: String, buttonMask: UInt8) {
        button.translatesAutoresizingMaskIntoConstraints = false
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.78)
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .medium
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 7, bottom: 8, trailing: 7)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 11, weight: .semibold)
            return outgoing
        }
        button.configuration = configuration
        button.setTitle(title, for: .normal)
        button.accessibilityLabel = title == "L Click" ? "Left mouse click" : "Right mouse click"
        button.addAction(UIAction { [weak self] _ in
            self?.vncClient.sendPointerButton(buttonMask: buttonMask, down: true)
        }, for: .touchDown)
        button.addAction(UIAction { [weak self] _ in
            self?.vncClient.sendPointerButton(buttonMask: buttonMask, down: false)
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        view.addSubview(button)
    }

    @objc private func toggleTouchKeyboard() {
        guard let panel = keyboardPanel else { return }
        panel.isHidden.toggle()
        if panel.isHidden { panel.releaseAllKeys() }
        keyboardToggle.setTitle(panel.isHidden ? "⌨ Keyboard" : "⌨ Hide keyboard", for: .normal)
        if !panel.isHidden { functionKeyBar.isHidden = true }
        else { refreshHardwareKeyboardState() }
    }

    private func emitKeyboardKey(_ key: String) {
        vncClient.tapKey(key)
    }

    private func hardwareKeyName(for key: UIKey) -> String? {
        // HID usage codes identify navigation, function and modifier keys.
        // Printable characters are sent without modifiers so Shift is separate.
        switch key.keyCode.rawValue {
        case 0x28, 0x58: return "ENTER"
        case 0x29: return "ESC"
        case 0x2A: return "BACKSPACE"
        case 0x2B: return "TAB"
        case 0x2C: return "SPACE"
        case 0x39: return "CAPSLOCK"
        case 0x46: return "PRINTSCREEN"
        case 0x47: return "SCROLLLOCK"
        case 0x48: return "PAUSE"
        case 0x3A...0x45: return "F\(Int(key.keyCode.rawValue) - 0x39)"
        case 0x49: return "INSERT"
        case 0x4A: return "HOME"
        case 0x4B: return "PAGEUP"
        case 0x4C: return "DELETE"
        case 0x4D: return "END"
        case 0x4E: return "PAGEDOWN"
        case 0x4F: return "RIGHT"
        case 0x50: return "LEFT"
        case 0x51: return "DOWN"
        case 0x52: return "UP"
        case 0x53: return "NUMLOCK"
        case 0x65: return "MENU"
        case 0xE0, 0xE4: return "CTRL"
        case 0xE1, 0xE5: return "SHIFT"
        case 0xE2, 0xE6: return "ALT"
        case 0xE3: return "META"
        case 0xE7: return "META_R"
        default:
            let characters = key.charactersIgnoringModifiers
            guard characters.unicodeScalars.count == 1,
                  let scalar = characters.unicodeScalars.first,
                  scalar.value >= 0x20, scalar.value <= 0x7E else { return nil }
            return String(scalar)
        }
    }

    private func sendHardwareKey(_ key: UIKey, isDown: Bool) -> Bool {
        let code = key.keyCode.rawValue
        if isDown {
            // Ignore UIKit key-repeat down events; the guest owns repeat policy.
            if hardwareKeySources[code] != nil { return true }
            guard let name = hardwareKeyName(for: key) else { return false }
            let source = "hardware-keyboard:\(code)"
            hardwareKeySources[code] = (name, source)
            vncClient.sendKey(name, down: true, source: source)
            return true
        }
        guard let active = hardwareKeySources.removeValue(forKey: code) else { return false }
        vncClient.sendKey(active.key, down: false, source: active.source)
        return true
    }

    private func releaseHardwareKeyboardKeys() {
        let heldKeys = Array(hardwareKeySources.values)
        hardwareKeySources.removeAll(keepingCapacity: true)
        for held in heldKeys {
            vncClient.sendKey(held.key, down: false, source: held.source)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, sendHardwareKey(key, isDown: true) else {
                unhandled.insert(press)
                continue
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, sendHardwareKey(key, isDown: false) else {
                unhandled.insert(press)
                continue
            }
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, sendHardwareKey(key, isDown: false) else {
                unhandled.insert(press)
                continue
            }
        }
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func releaseGuestInputs() {
        releaseHardwareKeyboardKeys()
        keyboardPanel?.releaseAllKeys()
        gamepad?.releaseAllButtons()
        MotionInputManager.shared.stop()
        ControllerInputManager.shared.stop()
    }

    private func registerKeyboardNotifications() {
        let center = NotificationCenter.default
        keyboardObservers.append(center.addObserver(
            forName: Notification.Name("GCKeyboardDidConnectNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.refreshHardwareKeyboardState() })
        keyboardObservers.append(center.addObserver(
            forName: Notification.Name("GCKeyboardDidDisconnectNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.refreshHardwareKeyboardState() })
        keyboardObservers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.releaseGuestInputs() })
        keyboardObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.viewIfLoaded?.window != nil else { return }
            self.becomeFirstResponder()
            self.refreshHardwareKeyboardState()
        })
    }

    private func refreshHardwareKeyboardState() {
        let connected = GCKeyboard.coalesced != nil
        // F-keys are only shown while a hardware keyboard is connected, and are
        // immediately hidden after disconnect or while the touch keyboard is open.
        functionKeyBar.isHidden = !connected || keyboardPanel?.isHidden == false
        if !connected {
            functionKeyBar.isHidden = true
            releaseHardwareKeyboardKeys()
        }
    }

    private func addTouchGamepad() {
        let pad = TouchGamepadView()
        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.onMove = { [weak self] point in self?.vncClient.setMovement(x: Float(point.x), y: Float(point.y), source: "touchgamepad") }
        pad.onLook = { [weak self] delta in
            guard VRSettings.shared.pointerLockEnabled else { return }
            self?.vncClient.movePointer(dx: Float(delta.x), dy: -Float(delta.y))
        }
        pad.onButton = { [weak self] key, down in self?.vncClient.sendButton(key, down: down, source: "touchgamepad") }
        view.addSubview(pad)
        NSLayoutConstraint.activate([
            pad.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pad.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pad.topAnchor.constraint(equalTo: view.topAnchor),
            pad.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        gamepad = pad
    }

    private func configureControllerInput() {
        let input = ControllerInputManager.shared
        input.onMove = { [weak self] x, y, source in self?.vncClient.setMovement(x: x, y: -y, source: source) }
        input.onLook = { [weak self] x, y in
            guard VRSettings.shared.pointerLockEnabled else { return }
            self?.vncClient.movePointer(dx: x, dy: y)
        }
        input.onButton = { [weak self] key, down, source in self?.vncClient.sendButton(key, down: down, source: source) }
        input.start()
    }

    private func configureMotionInput() {
        let motion = MotionInputManager.shared
        motion.onOrientation = { [weak self] yaw, pitch, roll in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastMotionStatusUpdate >= 0.25 else { return }
            self.lastMotionStatusUpdate = now
            let summary = String(format: "MOTION • Y %.2f P %.2f R %.2f", yaw, pitch, roll)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      case .running = self.engine.state,
                      self.vncClient.isConnected else { return }
                self.status.text = summary
            }
        }
        motion.onLookDelta = { [weak self] yaw, pitch in
            guard VRSettings.shared.pointerLockEnabled else { return }
            self?.vncClient.movePointer(dx: Float(yaw), dy: Float(pitch))
        }
        if vrSettings.mode == .cardboard { motion.start() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        resignFirstResponder()
        keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyboardObservers.removeAll()
        releaseGuestInputs()
        vncClient.stop()
        engine.stop()
        virtioGPU.stop()
    }
}
