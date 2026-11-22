import Foundation

final class GameLauncher {
    static let shared = GameLauncher()
    private init() {}

    @discardableResult
    func launch(executable: URL, workingDirectory: URL, arguments: [String] = [], completion: ((Result<GuestCPUExit, Error>) -> Void)? = nil) -> Bool {
        let result = GuestProcessManager.shared.inspect(executable)
        guard case let .success(format) = result,
              format == .windowsPE || format == .linuxELF else {
            EmulationLog.shared.write("Game launcher rejected an unsupported executable format")
            return false
        }

        let directoryValues = try? workingDirectory.resourceValues(forKeys: [.isDirectoryKey])
        guard directoryValues?.isDirectory == true else {
            EmulationLog.shared.write("Game launcher rejected a missing or non-directory working directory")
            return false
        }

        if format == .linuxELF {
            // Only the built-in diagnostic interpreter is integrated today.
            // Do not advertise FEXCore, Box64, AOT or a complete Linux syscall ABI
            // until their concrete adapters are packaged and verified.
            let availability = RuntimeBackendAvailability(installed: [.x86Interpreter])
            let request = RuntimeExecutionRequest(format: .linuxX64ELF)
            let plan = RuntimeBackendRouter.plan(for: request, availability: availability)
            for message in plan.explanation {
                EmulationLog.shared.write("[runtime-plan] " + message)
            }
            guard plan.isRunnableAsDiagnosticBringUp else {
                EmulationLog.shared.write("Linux ELF launch stopped: no diagnostic bring-up backend is installed.")
                return false
            }

            do {
                try ELFValidator.validate(url: executable)
            } catch {
                EmulationLog.shared.write("Linux ELF validation failed: \(error.localizedDescription)")
                completion?(.failure(error))
                return false
            }
            let accepted = LinuxELFRuntime.shared.launch(
                executable: executable,
                arguments: arguments,
                completion: completion
            )
            if !accepted {
                EmulationLog.shared.write("Linux ELF launch rejected: another guest process is already active.")
            }
            return accepted
        }

        let capabilities = RuntimeCapabilityRegistry.current
        for message in capabilities.diagnostics {
            EmulationLog.shared.write("[runtime-capability] " + message)
        }

        let request = RuntimeExecutionRequest(format: .windowsX64PE)
        let plan = RuntimeBackendRouter.plan(
            for: request,
            availability: capabilities.backendAvailability
        )
        for message in plan.explanation {
            EmulationLog.shared.write("[runtime-plan] " + message)
        }

        // This call still returns false until a concrete PE loader, Windows
        // compatibility stack and CPU execution adapter are packaged and
        // verified. The plan is now visible at the real launch boundary.
        guard plan.isExecutableWithInstalledBackends else {
            EmulationLog.shared.write("Game launch stopped: no verified Windows execution backend is installed.")
            return false
        }

        do {
            _ = try WindowsPELoader().load(executable)
        } catch {
            EmulationLog.shared.write("Game launcher rejected invalid or unsupported PE image: \(error.localizedDescription)")
            return false
        }

        let process = GuestProcess(executable: executable, workingDirectory: workingDirectory, format: format)
        SteamLibrary.shared.prepare()
        WindowsRuntime.shared.prepare()
        return WindowsRuntime.shared.launch(process)
    }
}


/// Runs the currently supported static Linux ELF subset through GuestMachine.
/// This is a bounded diagnostic interpreter path, not a dynamic Linux userspace.
final class LinuxELFRuntime {
    static let shared = LinuxELFRuntime()

    private static let guestMemorySize: UInt64 = 1024 * 1024 * 1024
    private static let batchInstructionLimit: UInt64 = 250_000

    private let queue = DispatchQueue(label: "com.xthrx.akatsubaki.linux-elf-runtime", qos: .userInitiated)
    private let lock = NSLock()
    private var activeMachine: GuestMachine?
    private var pendingCompletion: ((Result<GuestCPUExit, Error>) -> Void)?
    private var generation: UInt64 = 0
    private var isLaunching = false

    private init() {}

    @discardableResult
    func launch(
        executable: URL,
        arguments: [String],
        completion: ((Result<GuestCPUExit, Error>) -> Void)? = nil
    ) -> Bool {
        lock.lock()
        guard activeMachine == nil, !isLaunching else {
            lock.unlock()
            return false
        }
        generation &+= 1
        let token = generation
        isLaunching = true
        pendingCompletion = completion
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let machine = GuestMachine(
                configuration: .defaultLinux,
                memorySize: Self.guestMemorySize
            )
            guard machine.state == .configured else {
                machine.stop()
                self.finish(
                    token: token,
                    machine: nil,
                    result: .failure(GuestEngineError.memoryUnavailable)
                )
                return
            }

            self.lock.lock()
            guard token == self.generation else {
                self.lock.unlock()
                machine.stop()
                return
            }
            self.activeMachine = machine
            self.isLaunching = false
            self.lock.unlock()

            do {
                let image = try machine.loadELFImage(at: executable, arguments: arguments)
                EmulationLog.shared.write(
                    "Linux static ELF loaded at 0x" + String(image.entryPoint, radix: 16)
                )
                self.executeNextBatch(machine: machine, token: token)
            } catch {
                self.finish(token: token, machine: machine, result: .failure(error))
            }
        }
        return true
    }

    func stop() {
        lock.lock()
        generation &+= 1
        let machine = activeMachine
        activeMachine = nil
        isLaunching = false
        let callback = pendingCompletion
        pendingCompletion = nil
        lock.unlock()

        machine?.stop()
        if let callback {
            DispatchQueue.main.async { callback(.success(.interrupted)) }
        }
    }

    private func isCurrent(token: UInt64, machine: GuestMachine) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token == generation && activeMachine === machine
    }

    private func executeNextBatch(machine: GuestMachine, token: UInt64) {
        guard isCurrent(token: token, machine: machine) else { return }
        do {
            let exit = try machine.runBatch(maxInstructions: Self.batchInstructionLimit)
            if exit == .instructionLimit {
                queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in
                    self?.executeNextBatch(machine: machine, token: token)
                }
            } else {
                finish(token: token, machine: machine, result: .success(exit))
            }
        } catch {
            finish(token: token, machine: machine, result: .failure(error))
        }
    }

    private func finish(
        token: UInt64,
        machine: GuestMachine?,
        result: Result<GuestCPUExit, Error>
    ) {
        lock.lock()
        guard token == generation else {
            lock.unlock()
            return
        }
        if let machine, activeMachine !== machine {
            lock.unlock()
            return
        }
        activeMachine = nil
        isLaunching = false
        let callback = pendingCompletion
        pendingCompletion = nil
        lock.unlock()

        machine?.stop()
        if let callback {
            DispatchQueue.main.async { callback(result) }
        }
    }
}
