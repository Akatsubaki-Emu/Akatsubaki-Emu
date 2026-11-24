import Foundation

// Minimal host-only configuration and device bridge adapters. The execution
// engine under test is the production GuestMachine and native GuestMemory.
struct VMConfiguration {
    enum Architecture: String {
        case x86_64
        case arm64
        case riscv64
    }

    let architecture: Architecture
    let memoryMB: Int
}

final class HostDeviceBridge {
    struct DeviceInfo {
        let name: String
        let model: String
        let systemVersion: String
    }

    static let shared = HostDeviceBridge()

    func deviceInfo() -> DeviceInfo {
        DeviceInfo(name: "CI", model: "CI", systemVersion: "test")
    }

    func readSharedFile(relativePath: String) throws -> Data {
        throw NSError(domain: "HostDeviceBridgeStub", code: 1)
    }

    func writeSharedFile(_ data: Data, relativePath: String) throws {}
}

private final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ message: String) {
        lock.lock()
        storage.append(message)
        lock.unlock()
    }

    func joined() -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage.joined(separator: "\n")
    }

    func waitForMarker(occurrences: Int, timeout: TimeInterval = 3) throws {
        let marker = "KENRAN_BUTO_RUNTIME_OK"
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = joined().components(separatedBy: marker).count - 1
            if count >= occurrences { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw NSError(
            domain: "NativeGuestMachineSmoke",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Guest stdout did not contain the runtime marker \(occurrences) time(s)."]
        )
    }
}

@main
struct NativeGuestMachineSmoke {
    private static func runToExit(_ machine: GuestMachine) throws -> GuestCPUExit {
        for _ in 0..<4 {
            let result = try machine.runBatch(maxInstructions: 256)
            if result != .instructionLimit { return result }
        }
        throw NSError(
            domain: "NativeGuestMachineSmoke",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Guest did not exit within four 256-instruction batches."]
        )
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "NativeGuestMachineSmoke", code: 1)
        }
        let guestURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let capture = LogCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .emulationLogDidWrite,
            object: EmulationLog.shared,
            queue: nil
        ) { notification in
            if let message = notification.userInfo?["message"] as? String {
                capture.append(message)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let configuration = VMConfiguration(architecture: .x86_64, memoryMB: 256)
        let machine = GuestMachine(
            configuration: configuration,
            memorySize: UInt64(64 * 1024 * 1024)
        )
        precondition(machine.memory.isAvailable, "Native GuestMemory initialization failed")

        let image = try machine.loadELFImage(at: guestURL)
        precondition(image.entryPoint == 0x401000, "Unexpected runtime smoke entry point")
        let firstExit = try runToExit(machine)
        precondition(firstExit == .exited(0), "Native GuestMachine did not exit with status 0")
        precondition(machine.state == .stopped, "GuestMachine did not enter stopped state")
        precondition(machine.memory.readByte(offset: 0x402000) == 0x4C, "uname sysname was not written into native guest memory")
        precondition(machine.memory.readByte(offset: 0x402104) == 0x78, "uname machine was not written into native guest memory")
        precondition(machine.memory.readByte(offset: 0x401100) == 0x4B, "Runtime marker is missing from the executable segment")
        precondition(machine.memory.allocatedPageCount > 0, "Guest memory pages were not allocated")
        try capture.waitForMarker(occurrences: 1)
        let firstOutput = capture.joined()
        precondition(firstOutput.contains("Linux"), "Native guest stdout is missing uname sysname")
        precondition(firstOutput.contains("x86_64"), "Native guest stdout is missing uname machine")
        precondition(firstOutput.contains("KENRAN_BUTO_RUNTIME_OK"), "Native guest stdout is missing runtime marker")

        try machine.reset(entryPoint: image.entryPoint)
        let secondExit = try runToExit(machine)
        precondition(secondExit == .exited(0), "Second native GuestMachine launch did not exit with status 0")
        try capture.waitForMarker(occurrences: 2)

        machine.stop()
        precondition(machine.memory.allocatedPageCount == 0, "GuestMachine stop did not release native guest pages")
        precondition(machine.memory.readByte(offset: 0x402000) == nil, "Guest memory remained readable after stop")
        print("C-backed GuestMachine loaded, ran twice, captured stdout and released guest pages")
    }
}
