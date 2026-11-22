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

        let competingTranslatorPlan = RuntimeBackendRouter.plan(
            for: diagnosticRequest,
            availability: RuntimeBackendAvailability(installed: [.x86Interpreter, .fexCore])
        )
        precondition(competingTranslatorPlan.dynamicTranslationBackend == .fexCore)
        precondition(!competingTranslatorPlan.isRunnableAsDiagnosticBringUp)

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
