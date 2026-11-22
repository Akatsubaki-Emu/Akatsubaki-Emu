import Foundation

/// Evidence level for a runtime component. Only .operational capabilities may
/// be offered to the execution router. A loadable dylib is not proof that a
/// guest can boot or execute a workload correctly.
enum RuntimeCapabilityLevel: String, CaseIterable {
    case notProbed
    case missing
    case artifactPresent
    case loadable
    case validatedSubset
    case operational
}

struct RuntimeCapabilityRecord: Equatable {
    let level: RuntimeCapabilityLevel
    let detail: String
}

/// Central snapshot of backend evidence. Probes are deliberately conservative:
/// source files and manifest entries do not count as operational runtimes.
struct RuntimeCapabilityRegistry {
    private let records: [RuntimeBackend: RuntimeCapabilityRecord]

    private init(records: [RuntimeBackend: RuntimeCapabilityRecord]) {
        self.records = records
    }

    /// The app bundle is immutable for this process, so cache the first probe
    /// rather than repeatedly dlopen/close QEMU on every game launch.
    static let current = inspect(probeQEMU: false)

    static func inspect(bundle: Bundle = .main,
                        probeQEMU: Bool = false) -> RuntimeCapabilityRegistry {
        var records: [RuntimeBackend: RuntimeCapabilityRecord] = [:]
        for backend in RuntimeBackend.allCases {
            records[backend] = RuntimeCapabilityRecord(
                level: .missing,
                detail: "No verified runtime probe is registered for this backend."
            )
        }

        records[.x86Interpreter] = RuntimeCapabilityRecord(
            level: .validatedSubset,
            detail: "The bounded static-ELF diagnostic interpreter has a synthetic end-to-end smoke test; it is not a general Linux execution backend."
        )

        if probeQEMU {
            let jitStatus = QEMURuntimeStatus.inspect(bundle: bundle, requiresJIT: true)
            switch jitStatus {
            case .ready:
                records[.qemuTCG] = RuntimeCapabilityRecord(
                    level: .loadable,
                    detail: "The bundled QEMU JIT library loads and required lifecycle/JIT exports resolve; guest boot and device operation are not yet verified."
                )
            case .unavailable(let jitReason):
                switch QEMURuntimeStatus.inspect(bundle: bundle, requiresJIT: false) {
                case .ready:
                    records[.qemuTCG] = RuntimeCapabilityRecord(
                        level: .loadable,
                        detail: "The bundled QEMU TCI no-JIT library loads and required lifecycle exports resolve; guest boot and device operation are not yet verified."
                    )
                case .unavailable(let tciReason):
                    records[.qemuTCG] = RuntimeCapabilityRecord(
                        level: .missing,
                        detail: "JIT probe: \(jitReason) TCI probe: \(tciReason)"
                    )
                }
            }
        } else {
            records[.qemuTCG] = RuntimeCapabilityRecord(
                level: .notProbed,
                detail: "Deferred to the VM launch path to avoid loading the large QEMU dependency graph during a game-process launch."
            )
        }

        return RuntimeCapabilityRegistry(records: records)
    }

    func record(for backend: RuntimeBackend) -> RuntimeCapabilityRecord {
        records[backend] ?? RuntimeCapabilityRecord(
            level: .missing,
            detail: "No capability record was produced."
        )
    }

    /// Operational backends and the explicitly subset-validated diagnostic
    /// interpreter are exposed with distinct routing semantics.
    var backendAvailability: RuntimeBackendAvailability {
        let installed = Set(RuntimeBackend.allCases.filter {
            let level = record(for: $0).level
            return level == .operational
                || ($0 == .x86Interpreter && level == .validatedSubset)
        })
        // The syscall shim is only a subset; never advertise the full Linux ABI.
        return RuntimeBackendAvailability(installed: installed)
    }

    var diagnostics: [String] {
        RuntimeBackend.allCases.map { backend in
            let evidence = record(for: backend)
            return "\(backend.rawValue): \(evidence.level.rawValue) — \(evidence.detail)"
        }
    }
}
