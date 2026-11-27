import Foundation
import Dispatch

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

private final class GuestRunResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<GuestCPUExit, Error>?

    func set(_ result: Result<GuestCPUExit, Error>) {
        lock.lock()
        storage = result
        lock.unlock()
    }

    func get() -> Result<GuestCPUExit, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ message: String) {
        lock.lock()
        storage.append(message)
        lock.unlock()
    }

    func guestStdout() -> String {
        lock.lock()
        defer { lock.unlock() }
        let prefix = "[guest stdout] "
        return storage.compactMap { message in
            guard message.hasPrefix(prefix) else { return nil }
            return String(message.dropFirst(prefix.count))
        }.joined()
    }

    func waitForMarker(_ marker: String, occurrences: Int = 1, timeout: TimeInterval = 3) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = guestStdout().components(separatedBy: marker).count - 1
            if count >= occurrences { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw NSError(
            domain: "NativeGuestMachineSmoke",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Guest stdout did not contain marker \(marker) \(occurrences) time(s)."]
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
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "NativeGuestMachineSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Expected runtime and stdin smoke ELF paths."])
        }
        let guestURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let stdinGuestURL = URL(fileURLWithPath: CommandLine.arguments[2])
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
        try capture.waitForMarker("KENRAN_BUTO_RUNTIME_OK", occurrences: 1)
        let firstOutput = capture.guestStdout()
        precondition(firstOutput.contains("Linux"), "Native guest stdout is missing uname sysname")
        precondition(firstOutput.contains("x86_64"), "Native guest stdout is missing uname machine")
        precondition(firstOutput.contains("KENRAN_BUTO_RUNTIME_OK"), "Native guest stdout is missing runtime marker")

        try machine.reset(entryPoint: image.entryPoint)
        let secondExit = try runToExit(machine)
        precondition(secondExit == .exited(0), "Second native GuestMachine launch did not exit with status 0")
        try capture.waitForMarker("KENRAN_BUTO_RUNTIME_OK", occurrences: 2)

        machine.stop()
        precondition(machine.memory.allocatedPageCount == 0, "GuestMachine stop did not release native guest pages")
        precondition(machine.memory.readByte(offset: 0x402000) == 0, "Guest data memory was not zeroed after stop")
        precondition(machine.memory.readByte(offset: 0x401000) == 0, "Guest executable memory was not zeroed after stop")

        let stdinMachine = GuestMachine(
            configuration: configuration,
            memorySize: UInt64(64 * 1024 * 1024)
        )
        precondition(stdinMachine.memory.isAvailable, "Native stdin GuestMemory initialization failed")
        let stdinImage = try stdinMachine.loadELFImage(at: stdinGuestURL)
        precondition(stdinImage.entryPoint == 0x401000, "Unexpected stdin smoke entry point")
        let input = Data("hello\n".utf8)
        let stdinResult = GuestRunResult()
        let stdinCompleted = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            do {
                stdinResult.set(.success(try runToExit(stdinMachine)))
            } catch {
                stdinResult.set(.failure(error))
            }
            stdinCompleted.signal()
        }

        do {
            try capture.waitForMarker("KENRAN_BUTO_STDIN_READY", timeout: 5)
        } catch {
            stdinMachine.stop()
            _ = stdinCompleted.wait(timeout: .now() + .seconds(1))
            throw error
        }
        precondition(stdinMachine.enqueueStandardInput(input) == input.count,
                     "Native GuestMachine rejected input for its blocked read(0)")
        guard stdinCompleted.wait(timeout: .now() + .seconds(5)) == .success else {
            stdinMachine.stop()
            _ = stdinCompleted.wait(timeout: .now() + .seconds(1))
            preconditionFailure("Native GuestMachine did not wake blocked read(0) after console input arrived")
        }
        guard let stdinOutcome = stdinResult.get() else {
            preconditionFailure("Native stdin guest did not publish its execution result")
        }
        let stdinExit: GuestCPUExit
        switch stdinOutcome {
        case .success(let exit):
            stdinExit = exit
        case .failure(let error):
            throw error
        }
        precondition(stdinExit == .exited(0), "Native stdin guest did not exit with status 0")
        let readResult = stdinMachine.memory.readUInt64(offset: 0x402010)
        let writeResult = stdinMachine.memory.readUInt64(offset: 0x402018)
        let bufferWord = stdinMachine.memory.readUInt64(offset: 0x402020)
        print("Native stdin diagnostics read=\(String(describing: readResult)) write=\(String(describing: writeResult)) buffer=\(String(describing: bufferWord))")
        precondition(readResult == UInt64(input.count),
                     "Native read(0) returned \(String(describing: readResult)); expected \(input.count)")
        precondition(bufferWord == 0x0000_0A6F_6C6C_6568,
                     "Native read(0) did not place hello\\n in the guest stack buffer")
        precondition(writeResult == UInt64(input.count),
                     "Native write(1) returned \(String(describing: writeResult)); expected \(input.count)")
        // EmulationLog posts asynchronously; wait for the guest's final write
        // before asserting on the captured stream.
        try capture.waitForMarker("KENRAN_BUTO_STDIN_OK", timeout: 3)
        let stdinOutput = capture.guestStdout()
        precondition(stdinOutput.contains("KENRAN_BUTO_STDIN_READY"),
                     "Native GuestMachine did not announce its blocking read(0)")
        precondition(stdinOutput.contains("KENRAN_BUTO_STDIN_ECHO:hello\n"),
                     "Native GuestMachine did not echo asynchronously queued stdin")
        precondition(stdinOutput.contains("KENRAN_BUTO_STDIN_OK"),
                     "Native GuestMachine did not write the stdin completion marker")
        stdinMachine.stop()
        precondition(stdinMachine.memory.allocatedPageCount == 0,
                     "Native stdin GuestMachine stop did not release guest pages")
        print("C-backed GuestMachine woke blocked read(0), echoed asynchronous input and released guest pages")
        print("C-backed GuestMachine loaded, ran twice, captured stdout and released guest pages")
    }
}
