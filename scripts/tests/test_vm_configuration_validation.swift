import Foundation

// Lightweight stubs compile the real VM configuration and validation files
// without pulling UIKit or the application's settings UI into this test.
struct RenderResolution { let width: Int; let height: Int }
enum VMAccelerationBackend { case automatic, qemuJIT, qemuInterpreter, hypervisor }
struct DisplayFrameRate { let value: Int }
struct RuntimeSettings {
    static let shared = RuntimeSettings()
    var acceleration: VMAccelerationBackend = .automatic
    var renderResolution = RenderResolution(width: 1280, height: 720)
    var frameRate = DisplayFrameRate(value: 60)
}

@main
struct VMConfigurationValidationTests {
    private static let megabyte = UInt64(1024 * 1024)

    private static func configuration(memoryMB: Int) -> VMConfiguration {
        VMConfiguration(
            id: UUID(), name: "Test Linux", architecture: .x86_64,
            memoryMB: memoryMB, cpuCount: 2, accelerator: .tcg, gpu: .virtioGPU,
            displayWidth: 1280, displayHeight: 720, displayFPS: 60,
            bootWindows: false
        )
    }

    private static func expectInsufficient(memoryMB: Int, availableMB: Int, reserveMB: Int) throws {
        do {
            try configuration(memoryMB: memoryMB).validateForStart(
                availableMemoryBytes: UInt64(availableMB) * megabyte
            )
            fatalError("Expected insufficient-memory rejection")
        } catch let error as VMConfiguration.ValidationError {
            precondition(error == .insufficientAvailableMemory(
                requestedMB: memoryMB, availableMB: availableMB, reserveMB: reserveMB
            ))
        }
    }

    static func main() throws {
        let budgets: [(Int, Int)] = [
            (2048, 1024), (1536, 1024), (1024, 512),
            (800, 256), (600, 256), (400, 256)
        ]
        for (availableMB, expectedMB) in budgets {
            precondition(VMConfiguration.linuxMemoryBudgetMB(availableMemoryMB: availableMB) == expectedMB)
        }

        try configuration(memoryMB: 1024).validateForStart(availableMemoryBytes: 1536 * megabyte)
        try expectInsufficient(memoryMB: 1024, availableMB: 1535, reserveMB: 512)
        try configuration(memoryMB: 2048).validateForStart(availableMemoryBytes: 2560 * megabyte)
        try expectInsufficient(memoryMB: 4096, availableMB: 4096, reserveMB: 1024)

#if os(iOS) || os(tvOS)
        precondition(VMConfiguration.defaultLinux.memoryMB <= 1024)
        precondition(VMConfiguration.defaultLinux.cpuCount == 2)
#else
        precondition(VMConfiguration.defaultLinux.memoryMB == 4096)
#endif
        print("VM configuration memory budget tests passed: 10 cases")
    }
}
