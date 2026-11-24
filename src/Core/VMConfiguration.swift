import Foundation
#if os(iOS) || os(tvOS)
import os
#endif

struct VMConfiguration: Codable, Identifiable, Equatable {
    enum Architecture: String, Codable, CaseIterable {
        case x86_64, arm64, riscv64
    }

    enum Accelerator: String, Codable, CaseIterable {
        case tcg, jit
    }

    enum GPUModel: String, Codable, CaseIterable {
        case virtioGPU = "virtio-gpu-pci"
        case virtioGPUGL = "virtio-gpu-gl-pci"
        case virtioRAMFBGL = "virtio-ramfb-gl"
    }

    let id: UUID
    var name: String
    var architecture: Architecture
    var memoryMB: Int
    var cpuCount: Int
    var accelerator: Accelerator
    var gpu: GPUModel
    var displayWidth: Int
    var displayHeight: Int
    var displayFPS: Int
    var bootWindows: Bool
    var bootUEFI: Bool? = nil

    var requiresUEFI: Bool { bootUEFI ?? (bootWindows || name == "SteamOS Gaming Mode") }

    static var defaultAccelerator: Accelerator {
        switch RuntimeSettings.shared.acceleration {
        case .automatic, .qemuJIT: return .jit
        case .qemuInterpreter, .hypervisor: return .tcg
        }
    }

    /// Keep the first iOS/tvOS Linux guest within the current app memory budget.
    /// Leave at least one third of the process budget for QEMU, VNC, Metal and UI.
    static func linuxMemoryBudgetMB(availableMemoryMB: Int) -> Int {
        let hostReserveMB = max(512, availableMemoryMB / 3)
        let budgetMB = min(1024, max(256, availableMemoryMB - hostReserveMB))
        return max(256, (budgetMB / 256) * 256)
    }

    static var recommendedLinuxMemoryMB: Int {
#if os(iOS) || os(tvOS)
        let availableMB = Int(os_proc_available_memory() / (1024 * 1024))
        return linuxMemoryBudgetMB(availableMemoryMB: availableMB)
#else
        return 4096
#endif
    }

    static var defaultWindows: VMConfiguration {
        let resolution = RuntimeSettings.shared.renderResolution
#if os(iOS) || os(tvOS)
        let memoryMB = 2048
        let cpuCount = 2
#else
        let memoryMB = 4096
        let cpuCount = 4
#endif
        return VMConfiguration(
            id: UUID(), name: "Windows Steam", architecture: .x86_64,
            memoryMB: memoryMB, cpuCount: cpuCount, accelerator: defaultAccelerator,
            gpu: .virtioGPU,
            displayWidth: resolution.width,
            displayHeight: resolution.height,
            displayFPS: RuntimeSettings.shared.frameRate.value,
            bootWindows: true, bootUEFI: true
        )
    }

    static var defaultLinux: VMConfiguration {
        let resolution = RuntimeSettings.shared.renderResolution
#if os(iOS) || os(tvOS)
        let cpuCount = 2
#else
        let cpuCount = 4
#endif
        return VMConfiguration(
            id: UUID(), name: "Ubuntu", architecture: .x86_64, memoryMB: recommendedLinuxMemoryMB,
            cpuCount: cpuCount, accelerator: defaultAccelerator, gpu: .virtioGPU,
            displayWidth: resolution.width,
            displayHeight: resolution.height,
            displayFPS: RuntimeSettings.shared.frameRate.value,
            bootWindows: false, bootUEFI: false
        )
    }

    /// DroidDeck-inspired gaming-oriented Linux guest profile.
    /// This configures resources and input devices; it does not bundle Valve's
    /// SteamOS distribution or make unsupported GPU features available.
    static var defaultSteamOS: VMConfiguration {
#if os(iOS) || os(tvOS)
        let memoryMB = 2048
        let cpuCount = 2
#else
        let memoryMB = 4096
        let cpuCount = 4
#endif
        return VMConfiguration(
            id: UUID(), name: "SteamOS Gaming Mode", architecture: .x86_64,
            memoryMB: memoryMB, cpuCount: cpuCount, accelerator: defaultAccelerator, gpu: .virtioGPU,
            displayWidth: 1280, displayHeight: 800, displayFPS: 60,
            bootWindows: false, bootUEFI: true
        )
    }
}
