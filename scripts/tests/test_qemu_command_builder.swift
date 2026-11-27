import Foundation

// Minimal value-compatible VMConfiguration fixture. The test compiles the real
// QEMUCommandBuilder.swift without pulling the app's settings/UI dependencies.
struct VMConfiguration {
    enum Accelerator: Equatable {
        case jit
        case tcg
    }

    enum GPUModel: String {
        case virtioGPU = "virtio-gpu-pci"
    }

    var memoryMB: Int
    var cpuCount: Int
    var accelerator: Accelerator
    var gpu: GPUModel
    var bootWindows: Bool
}

@main
struct QEMUCommandBuilderBehaviorTests {
    private static func configuration(_ accelerator: VMConfiguration.Accelerator) -> VMConfiguration {
        VMConfiguration(
            memoryMB: 4096,
            cpuCount: 4,
            accelerator: accelerator,
            gpu: .virtioGPU,
            bootWindows: false
        )
    }

    private static func accelArgument(_ arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: "-accel"),
              arguments.indices.contains(index + 1) else {
            fatalError("QEMU command line is missing its -accel argument")
        }
        return arguments[index + 1]
    }

    static func main() {
        // Requested JIT, but runtime selected TCI after JIT preflight failed.
        var fallbackConfiguration = configuration(.jit)
        fallbackConfiguration.accelerator = .tcg
        let fallbackArguments = QEMUCommandBuilder(configuration: fallbackConfiguration).arguments()
        precondition(accelArgument(fallbackArguments) == "tcg")
        precondition(!fallbackArguments.contains(where: { $0.contains("split-wx=on") }))
        precondition(!fallbackArguments.contains(where: { $0.contains("tb-size=128") }))

        // A VM that requested TCI must produce the same no-JIT command mode.
        let requestedTCIArguments = QEMUCommandBuilder(configuration: configuration(.tcg)).arguments()
        precondition(accelArgument(requestedTCIArguments) == "tcg")
        precondition(!requestedTCIArguments.contains(where: { $0.contains("split-wx=on") }))

        // A genuine JIT launch retains the JIT-only split-WX accelerator option.
        let jitArguments = QEMUCommandBuilder(configuration: configuration(.jit)).arguments()
        precondition(accelArgument(jitArguments) == "tcg,tb-size=128,split-wx=on")

        // Pause/resume retains QEMU while the app is open, but guest ACPI
        // shutdown must let the native worker exit and run qemu_cleanup.
        precondition(!requestedTCIArguments.contains("-no-shutdown"))
        precondition(!jitArguments.contains("-no-shutdown"))
        precondition(requestedTCIArguments.contains("-qmp"))
        let qmpIndex = requestedTCIArguments.firstIndex(of: "-qmp")
        precondition(qmpIndex != nil && requestedTCIArguments.indices.contains(qmpIndex! + 1))
        precondition(requestedTCIArguments[qmpIndex! + 1] ==
                     "unix:\(QEMUCommandBuilder.qmpSocketPath),server=on,wait=off")

        print("QEMU command-builder effective accelerator tests passed: JIT fallback -> TCI, requested TCI -> TCI, requested JIT -> split-WX JIT")
    }
}
