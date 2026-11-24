import Foundation

/// Coordinates guest sessions over one process-lifetime QEMU runtime.
/// Guest stop pauses the VM through QMP; the next launch resets and resumes it.
final class VMEngine {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case stopping
        case failed(String)
    }

    private(set) var state: State = .stopped
    var onStateChange: ((State) -> Void)?
    private let configuration: VMConfiguration
    private var backend: QEMUBackend?
    private var monitor: DispatchSourceTimer?
    private var startupDeadline: DispatchTime?

    init(configuration: VMConfiguration) {
        self.configuration = configuration
    }

    private func setState(_ newState: State) {
        state = newState
        let callback = onStateChange
        DispatchQueue.main.async { callback?(newState) }
    }

    func start() {
        guard case .stopped = state else { return }
        setState(.failed("Choose a guest disk image in the VM setup screen before starting the engine."))
        EmulationLog.shared.write("VM start blocked: no guest disk image was supplied.")
    }

    func start(diskImage: URL, writableDiskImage: URL? = nil, firmware: URL? = nil) {
        guard case .stopped = state else { return }
        setState(.starting)
        EmulationLog.shared.write("Preparing session: \(configuration.name)")
        EmulationLog.shared.write("Guest: \(configuration.bootWindows ? "Windows" : "Linux")")
        EmulationLog.shared.write("CPU=\(configuration.architecture.rawValue) RAM=\(configuration.memoryMB)MB CPUs=\(configuration.cpuCount)")
        EmulationLog.shared.write("Requested accelerator=\(configuration.accelerator.rawValue); GPU=\(configuration.gpu.rawValue); FPS=\(configuration.displayFPS)")

        do {
            try configuration.validateForStart()
            guard configuration.architecture == .x86_64 else {
                throw GuestEngineError.backendNotInstalled(configuration.architecture)
            }
            let candidate = QEMUBackend(configuration: configuration)
            backend = candidate
            try candidate.start(diskImage: diskImage, writableDiskImage: writableDiskImage, firmware: firmware)
            startupDeadline = .now() + 60
            EmulationLog.shared.write("QEMU launch accepted; waiting for native initialization.")
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self, weak candidate] in
                guard let self, let candidate else { return }
                self.checkStartup(candidate)
            }
            monitor = timer
            timer.resume()
        } catch {
            backend?.stop()
            backend = nil
            setState(.failed(error.localizedDescription))
            EmulationLog.shared.write("Session start failed: \(error.localizedDescription)")
        }
    }

    private func checkStartup(_ candidate: QEMUBackend) {
        if case .stopping = state {
            guard !candidate.isRunning else { return }
            monitor?.cancel()
            monitor = nil
            backend = nil
            setState(.stopped)
            EmulationLog.shared.write("QEMU guest paused; persistent runtime retained for the next launch.")
            return
        }

        guard case .starting = state else {
            if case .running = state, !candidate.isRunning {
                fail("QEMU main loop exited. Check the emulator log and guest boot image.")
            }
            return
        }

        if candidate.isRunning {
            setState(.running)
            startupDeadline = nil
            monitor?.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(100))
            EmulationLog.shared.write("QEMU main loop is active. Guest OS boot is not independently verified.")
            return
        }
        if let error = candidate.lastError {
            fail("QEMU startup/runtime error: \(error)")
            return
        }
        if !candidate.isActive {
            fail("QEMU initialization ended before its main loop became active.")
            return
        }
        if let deadline = startupDeadline, DispatchTime.now() >= deadline {
            fail("QEMU did not enter its active main loop within 60 seconds. Verify the bundled runtime and its startup logs.")
        }
    }

    private func fail(_ message: String) {
        monitor?.cancel()
        monitor = nil
        startupDeadline = nil
        backend?.stop()
        backend = nil
        setState(.failed(message))
        EmulationLog.shared.write(message)
    }

    func stop() {
        guard case .stopped = state else {
            setState(.stopping)
            startupDeadline = nil
            monitor?.cancel()
            monitor = nil

            guard let candidate = backend else {
                setState(.stopped)
                return
            }
            guard candidate.stop() else {
                let message = candidate.lastError ?? "QEMU did not acknowledge the pause request."
                setState(.failed("Unable to pause the QEMU guest: \(message)"))
                EmulationLog.shared.write("QEMU pause failed: \(message)")
                return
            }

            backend = nil
            setState(.stopped)
            EmulationLog.shared.write("Stopped guest session: \(configuration.name); QEMU process retained for repeat launches.")
            return
        }
    }
}
