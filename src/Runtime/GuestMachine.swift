import Foundation

/// CPU backend boundary. A real emulator implementation must be supplied.
protocol GuestCPUBackend: AnyObject {
    var architecture: VMConfiguration.Architecture { get }
    var instructionCount: UInt64 { get }
    func reset(entryPoint: UInt64) throws
    func run(maxInstructions: UInt64) throws -> GuestCPUExit
    func requestStop()
    func resume()
}

enum GuestCPUExit: Equatable {
    case instructionLimit
    case halted
    case interrupted
    case unsupportedInstruction(address: UInt64)
    case memoryFault(address: UInt64)
    case backendUnavailable(String)
}

enum GuestEngineError: LocalizedError {
    case invalidInstructionBudget
    case backendNotInstalled(VMConfiguration.Architecture)
    case memoryUnavailable
    case invalidState(String)

    var errorDescription: String? {
        switch self {
        case .invalidInstructionBudget:
            return "The guest CPU instruction budget must be greater than zero."
        case .backendNotInstalled(let architecture):
            return "No guest CPU backend is installed for \(architecture.rawValue)."
        case .memoryUnavailable:
            return "Native guest memory could not be allocated on this device."
        case .invalidState(let detail):
            return detail
        }
    }
}

final class GuestMachine {
    enum State: Equatable {
        case stopped, configured, running, paused, failed(String)
    }

    let configuration: VMConfiguration
    let memory: GuestMemory
    /// Host services available to a future CPU/network backend adapter.
    let hostBridge = HostDeviceBridge.shared
    private(set) var state: State = .stopped
    private(set) var lastExit: GuestCPUExit?
    private var cpu: GuestCPUBackend?
    private let executionLock = NSLock()

    private func withExecutionLock<T>(_ body: () throws -> T) rethrows -> T {
        executionLock.lock()
        defer { executionLock.unlock() }
        return try body()
    }

    init(configuration: VMConfiguration, memorySize: UInt64? = nil) {
        self.configuration = configuration
        // Keep malformed or imported configurations from overflowing the
        // byte conversion or requesting unbounded host memory in this prototype.
        let maximumGuestBytes: UInt64 = 16 * 1024 * 1024 * 1024
        let requestedMB = min(max(configuration.memoryMB, 256), 16_384)
        let defaultSize = UInt64(requestedMB) * 1024 * 1024
        let requestedSize = memorySize.map { min(max($0, GuestMemory.pageSize), maximumGuestBytes) } ?? defaultSize
        self.memory = GuestMemory(size: requestedSize)
        guard self.memory.isAvailable else {
            self.state = .failed("Unable to create the native guest-memory store.")
            return
        }
        // Ship the small x86-64 interpreter as the first runnable backend.
        // Other architectures still require a compatible backend integration.
        if configuration.architecture == .x86_64 {
            self.cpu = X86_64Interpreter(memory: self.memory)
            self.state = .configured
        } else {
            self.state = .failed(
                GuestEngineError.backendNotInstalled(configuration.architecture).localizedDescription
            )
        }
    }

    /// Host device details for a guest RPC adapter. This is not guest-visible
    /// until a backend implements a transport (virtio-serial or a virtual NIC).
    func hostDeviceInfo() -> HostDeviceBridge.DeviceInfo {
        hostBridge.deviceInfo()
    }

    func readHostSharedFile(relativePath: String) throws -> Data {
        try hostBridge.readSharedFile(relativePath: relativePath)
    }

    func writeHostSharedFile(_ data: Data, relativePath: String) throws {
        try hostBridge.writeSharedFile(data, relativePath: relativePath)
    }

    func installCPUBackend(_ backend: GuestCPUBackend) throws {
        guard memory.isAvailable else { throw GuestEngineError.memoryUnavailable }
        guard backend.architecture == configuration.architecture else {
            throw GuestEngineError.backendNotInstalled(configuration.architecture)
        }
        try withExecutionLock {
            cpu?.requestStop()
            backend.resume()
            cpu = backend
            state = .configured
            lastExit = nil
        }
    }

    /// Loads an ELF64 image into guest memory and initializes the CPU at its
    /// entry point. Loading requires a compatible, real CPU backend to be installed.
    @discardableResult
    func loadELFImage(at url: URL) throws -> ELF64Loader.Image {
        guard memory.isAvailable else { throw GuestEngineError.memoryUnavailable }
        guard let cpu else {
            let error = GuestEngineError.backendNotInstalled(configuration.architecture)
            state = .failed(error.localizedDescription)
            throw error
        }

        return try withExecutionLock {
            do {
                let image = try ELF64Loader().load(url, into: memory,
                                                   expectedArchitecture: configuration.architecture)
                try cpu.reset(entryPoint: image.entryPoint)
                lastExit = nil
                state = .configured
                return image
            } catch {
                state = .failed(error.localizedDescription)
                throw error
            }
        }
    }

    /// Resets CPU registers only. Loaded guest memory is deliberately preserved.
    func reset(entryPoint: UInt64) throws {
        guard memory.isAvailable else { throw GuestEngineError.memoryUnavailable }
        guard let cpu else {
            let error = GuestEngineError.backendNotInstalled(configuration.architecture)
            state = .failed(error.localizedDescription)
            throw error
        }
        try withExecutionLock {
            do {
                try cpu.reset(entryPoint: entryPoint)
                lastExit = nil
                state = .configured
            } catch {
                state = .failed(error.localizedDescription)
                throw error
            }
        }
    }

    @discardableResult
    func runBatch(maxInstructions: UInt64) throws -> GuestCPUExit {
        guard maxInstructions > 0 else { throw GuestEngineError.invalidInstructionBudget }
        guard memory.isAvailable else { throw GuestEngineError.memoryUnavailable }
        return try withExecutionLock {
        guard state == .configured else {
            throw GuestEngineError.invalidState("The guest must be configured before running; resume a paused guest or load/reset an image first.")
        }
        guard let cpu else {
            let error = GuestEngineError.backendNotInstalled(configuration.architecture)
            state = .failed(error.localizedDescription)
            throw error
        }
        state = .running
        do {
            let exit = try cpu.run(maxInstructions: maxInstructions)
            lastExit = exit
            switch exit {
            case .instructionLimit: state = .configured
            case .interrupted: state = .paused
            case .halted: state = .stopped
            case .unsupportedInstruction, .memoryFault, .backendUnavailable:
                state = .failed(String(describing: exit))
            }
            return exit
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
        }
    }

    func pause() {
        let activeCPU = cpu
        activeCPU?.requestStop()
        withExecutionLock {
            if state == .running {
                state = .paused
            } else if state != .paused {
                activeCPU?.resume()
            }
        }
    }

    /// Resumes a paused interpreter without resetting registers or guest memory.
    @discardableResult
    func resume() -> Bool {
        withExecutionLock {
            guard state == .paused, let cpu else { return false }
            cpu.resume()
            state = .configured
            return true
        }
    }

    func stop() {
        cpu?.requestStop()
        withExecutionLock {
            cpu?.requestStop()
            memory.clear()
            state = .stopped
            lastExit = nil
        }
    }
}
