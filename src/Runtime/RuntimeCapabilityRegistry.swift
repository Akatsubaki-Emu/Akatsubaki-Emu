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
            detail: "The bounded static-ELF diagnostic interpreter has repository smoke tests; physical iOS guest execution is not yet verified and it is not a general Linux backend."
        )

        if probeQEMU {
            let jitStatus = QEMURuntimeStatus.inspect(bundle: bundle, requiresJIT: true)
            let tciStatus = QEMURuntimeStatus.inspect(bundle: bundle, requiresJIT: false)
            let jitReady: Bool
            let tciReady: Bool
            let jitDetail: String
            let tciDetail: String
            switch jitStatus {
            case .ready:
                jitReady = true
                jitDetail = "JIT runtime loads and required exports resolve"
            case .unavailable(let reason):
                jitReady = false
                jitDetail = "JIT unavailable: \(reason)"
            }
            switch tciStatus {
            case .ready:
                tciReady = true
                tciDetail = "no-JIT TCI runtime loads and required exports resolve"
            case .unavailable(let reason):
                tciReady = false
                tciDetail = "TCI unavailable: \(reason)"
            }
            records[.qemuTCG] = RuntimeCapabilityRecord(
                level: (jitReady || tciReady) ? .loadable : .missing,
                detail: "\(jitDetail); \(tciDetail). Guest boot and device operation remain unverified."
            )
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
