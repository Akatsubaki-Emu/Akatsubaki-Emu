import Foundation

@main
struct ExecutionBackendRouterTests {
    static func main() {
        let diagnosticRequest = RuntimeExecutionRequest(format: .linuxX64ELF)
        let diagnosticPlan = RuntimeBackendRouter.plan(
            for: diagnosticRequest,
            availability: RuntimeBackendAvailability(installed: [.x86Interpreter])
        )
        precondition(diagnosticPlan.diagnosticFallback == .x86Interpreter)
        precondition(diagnosticPlan.missingRequiredLayers == [.linuxSyscallABI])
        precondition(diagnosticPlan.isRunnableAsDiagnosticBringUp)
        precondition(!diagnosticPlan.isExecutableWithInstalledBackends)

        // FEXCore is the primary Linux x86-64 dynamic translator. If both
        // engines are installed, Box64 must not be selected for this process.
        let competingTranslatorPlan = RuntimeBackendRouter.plan(
            for: diagnosticRequest,
            availability: RuntimeBackendAvailability(
                installed: [.x86Interpreter, .fexCore, .box64],
                layers: [.linuxSyscallABI]
            )
        )
        precondition(competingTranslatorPlan.dynamicTranslationBackend == .fexCore)
        precondition(competingTranslatorPlan.candidateOrder.first == .fexCore)
        precondition(!competingTranslatorPlan.candidateOrder.contains(.box64))
        precondition(competingTranslatorPlan.isExecutableWithInstalledBackends)
        precondition(!competingTranslatorPlan.isRunnableAsDiagnosticBringUp)

        // Box64 is selected only when FEXCore is unavailable.
        let box64FallbackPlan = RuntimeBackendRouter.plan(
            for: diagnosticRequest,
            availability: RuntimeBackendAvailability(
                installed: [.x86Interpreter, .box64],
                layers: [.linuxSyscallABI]
            )
        )
        precondition(box64FallbackPlan.dynamicTranslationBackend == .box64)
        precondition(!box64FallbackPlan.candidateOrder.contains(.fexCore))
        precondition(box64FallbackPlan.isExecutableWithInstalledBackends)

        // The Windows route follows the same one-engine policy.
        let windowsRequest = RuntimeExecutionRequest(format: .windowsX64PE)
        let windowsLayers: Set<RuntimeCompatibilityLayer> = [
            .windowsDLLLoader, .win32AndNT, .wineOrProton
        ]
        let windowsPlan = RuntimeBackendRouter.plan(
            for: windowsRequest,
            availability: RuntimeBackendAvailability(
                installed: [.wineWithFEX, .wineWithBox64],
                layers: windowsLayers
            )
        )
        precondition(windowsPlan.dynamicTranslationBackend == .wineWithFEX)
        precondition(!windowsPlan.candidateOrder.contains(.wineWithBox64))

        // Kernel-mode anti-cheat is not made compatible by user-mode translation.
        let protectedWindowsRequest = RuntimeExecutionRequest(
            format: .windowsX64PE,
            requiresKernelDriver: true,
            antiCheatEnabled: true
        )
        let protectedWindowsPlan = RuntimeBackendRouter.plan(
            for: protectedWindowsRequest,
            availability: RuntimeBackendAvailability(
                installed: [.wineWithFEX, .wineWithBox64, .qemuTCG]
            )
        )
        precondition(protectedWindowsPlan.fullSystemFallback == .qemuTCG)
        precondition(protectedWindowsPlan.dynamicTranslationBackend == nil)
        precondition(protectedWindowsPlan.antiCheatAssessment == .kernelDriverRequiresSupportedWindowsKernel)
        precondition(!protectedWindowsPlan.isExecutableWithInstalledBackends)

        let noDiagnosticPlan = RuntimeBackendRouter.plan(
            for: diagnosticRequest,
            availability: RuntimeBackendAvailability()
        )
        precondition(!noDiagnosticPlan.isRunnableAsDiagnosticBringUp)

        let arm32Request = RuntimeExecutionRequest(format: .linuxARM32ELF)
        let translatorOnly = RuntimeBackendAvailability(installed: [.a32rt])
        let translatorOnlyPlan = RuntimeBackendRouter.plan(
            for: arm32Request,
            availability: translatorOnly
        )
        precondition(translatorOnlyPlan.architectureBackend == .a32rt)
        precondition(translatorOnlyPlan.requiredLayers == [.linuxSyscallABI])
        precondition(translatorOnlyPlan.missingRequiredLayers == [.linuxSyscallABI])
        precondition(!translatorOnlyPlan.isExecutableWithInstalledBackends)

        let withABIAvailability = RuntimeBackendAvailability(
            installed: [.a32rt],
            layers: [.linuxSyscallABI]
        )
        let withABIPlan = RuntimeBackendRouter.plan(
            for: arm32Request,
            availability: withABIAvailability
        )
        precondition(withABIPlan.missingRequiredLayers.isEmpty)
        precondition(withABIPlan.isExecutableWithInstalledBackends)

        let noTranslatorAvailability = RuntimeBackendAvailability(
            layers: [.linuxSyscallABI]
        )
        let noTranslatorPlan = RuntimeBackendRouter.plan(
            for: arm32Request,
            availability: noTranslatorAvailability
        )
        precondition(noTranslatorPlan.architectureBackend == nil)
        precondition(!noTranslatorPlan.isExecutableWithInstalledBackends)

        let fullSystemRequest = RuntimeExecutionRequest(
            format: .linuxARM32ELF,
            requiresFullOperatingSystem: true
        )
        let fullSystemPlan = RuntimeBackendRouter.plan(
            for: fullSystemRequest,
            availability: RuntimeBackendAvailability(installed: [.qemuTCG])
        )
        precondition(fullSystemPlan.fullSystemFallback == .qemuTCG)
        precondition(fullSystemPlan.isExecutableWithInstalledBackends)

        print("Linux ARM32 routing requires both a32rt and the Linux syscall ABI")
    }
}
