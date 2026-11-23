import Foundation

/// Owns one native QEMU session and keeps any Files-provider security scopes
/// alive for the full lifetime of QEMU (not just while constructing argv).
final class QEMUNativeRuntime {
    enum RuntimeError: LocalizedError {
        case runtimeUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .runtimeUnavailable(let message): return message
            }
        }
    }

    private(set) var started = false
    private var scopedURLs: [URL] = []

    func start(configuration: VMConfiguration, diskImage: URL, writableDiskImage: URL? = nil,
               firmware: URL? = nil) throws {
        guard !started else { return }
        try configuration.validateForStart()
        guard configuration.architecture == .x86_64 else {
            throw RuntimeError.runtimeUnavailable(
                "The bundled QEMU bridge is currently configured for x86_64 guests only."
            )
        }

        let requestedJIT = configuration.accelerator == .jit
        var effectiveConfiguration = configuration
        var requiresJIT = requestedJIT
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if requiresJIT && !JITCoordinator.shared.isQEMUJITReady {
            requiresJIT = false
            effectiveConfiguration.accelerator = .tcg
            EmulationLog.shared.write(
                "QEMU JIT is unavailable on this device; selecting the bundled no-JIT TCI runtime."
            )
        }
        #endif

        var runtimeStatus = QEMURuntimeStatus.inspect(requiresJIT: requiresJIT)
        if case .unavailable(let jitReason) = runtimeStatus, requiresJIT {
            let tciStatus = QEMURuntimeStatus.inspect(requiresJIT: false)
            switch tciStatus {
            case .ready:
                requiresJIT = false
                effectiveConfiguration.accelerator = .tcg
                runtimeStatus = tciStatus
                EmulationLog.shared.write(
                    "QEMU JIT runtime failed preflight; falling back to TCI: \(jitReason)"
                )
            case .unavailable(let tciReason):
                throw RuntimeError.runtimeUnavailable(
                    "Neither QEMU execution mode is available. JIT: \(jitReason) TCI: \(tciReason)"
                )
            }
        }

        let libraryURL: URL
        let dataDirectory: URL
        switch runtimeStatus {
        case .unavailable(let reason):
            throw RuntimeError.runtimeUnavailable(reason)
        case .ready(let library, let data):
            libraryURL = library
            dataDirectory = data
        }

        let selectedFirmware: URL?
        let variablesTemplate: URL?
        if let firmware {
            selectedFirmware = firmware
            variablesTemplate = Self.findUEFIVariables(matching: firmware, in: dataDirectory)
        } else if configuration.requiresUEFI {
            guard let pair = Self.findUEFIFirmwarePair(in: dataDirectory) else {
                throw RuntimeError.runtimeUnavailable(
                    "This VM profile requires a matching UEFI code/variable-store pair: OVMF_CODE.fd + OVMF_VARS.fd, OVMF_CODE_4M.fd + OVMF_VARS_4M.fd, or edk2-x86_64-code.fd + edk2-x86_64-vars.fd."
                )
            }
            selectedFirmware = pair.code
            variablesTemplate = pair.variables
        } else {
            selectedFirmware = nil
            variablesTemplate = nil
        }

        let selectedFirmwareVariables: URL?
        if let selectedFirmware {
            guard let variablesTemplate else {
                throw RuntimeError.runtimeUnavailable(
                    "The selected UEFI code image \(selectedFirmware.lastPathComponent) has no matching bundled variable-store template."
                )
            }
            selectedFirmwareVariables = try Self.makeWritableUEFIVariables(from: variablesTemplate, for: configuration.id)
        } else {
            selectedFirmwareVariables = nil
        }

        if let writableDiskImage,
           writableDiskImage.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
            == diskImage.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL {
            throw RuntimeError.runtimeUnavailable("The boot image and writable VM disk must be different files.")
        }

        var newlyScoped: [URL] = []
        for url in [diskImage, writableDiskImage, selectedFirmware].compactMap({ $0 }) {
            let granted = url.startAccessingSecurityScopedResource()
            if granted { newlyScoped.append(url) }
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
                    throw RuntimeError.runtimeUnavailable(
                        "The selected disk or firmware must be a non-empty regular file."
                    )
                }
            } catch {
                newlyScoped.forEach { $0.stopAccessingSecurityScopedResource() }
                throw error
            }
        }

        let args = QEMUCommandBuilder(configuration: effectiveConfiguration)
            .arguments(diskImage: diskImage, writableDiskImage: writableDiskImage,
                       firmware: selectedFirmware, firmwareVariables: selectedFirmwareVariables)
            + ["-L", dataDirectory.path]
        let arguments = ["qemu-system-\(configuration.architecture.rawValue)"] + args
        let strings: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        defer { strings.forEach { if let value = $0 { free(value) } } }
        var errorBuffer = [CChar](repeating: 0, count: 512)

        let pointerStrings: [UnsafePointer<CChar>] = strings.compactMap { value in
            value.map { UnsafePointer<CChar>($0) }
        }
        guard pointerStrings.count == arguments.count else {
            newlyScoped.forEach { $0.stopAccessingSecurityScopedResource() }
            throw RuntimeError.runtimeUnavailable("Unable to allocate QEMU argument strings.")
        }

        let success = pointerStrings.withUnsafeBufferPointer { pointerBuffer -> Bool in
            guard let argv = pointerBuffer.baseAddress else { return false }
            return libraryURL.path.withCString { libraryPath in
                errorBuffer.withUnsafeMutableBufferPointer { errorPointer -> Bool in
                    guard let error = errorPointer.baseAddress else { return false }
                    return isteam_qemu_start(Int32(pointerBuffer.count), argv,
                                             libraryPath, requiresJIT, error,
                                             Int32(errorPointer.count))
                }
            }
        }

        guard success else {
            newlyScoped.forEach { $0.stopAccessingSecurityScopedResource() }
            let message = String(cString: errorBuffer)
            throw RuntimeError.runtimeUnavailable(
                message.isEmpty ? "The native QEMU bridge failed to start." : message
            )
        }

        scopedURLs = newlyScoped
        started = true
        EmulationLog.shared.write("QEMU launch requested with boot media \(diskImage.lastPathComponent)"
            + (writableDiskImage.map { " and writable disk \($0.lastPathComponent)" } ?? ""))
    }

    private static func containedRegularFile(named names: [String], in directory: URL) -> URL? {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        func validated(_ candidate: URL) -> URL? {
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
            let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
            guard resolved.path.hasPrefix(prefix),
                  values?.isRegularFile == true else { return nil }
            return resolved
        }

        for name in names {
            if let candidate = validated(directory.appendingPathComponent(name)) {
                return candidate
            }
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where names.contains(url.lastPathComponent) {
            if let candidate = validated(url) { return candidate }
        }
        return nil
    }

    private static func findUEFIFirmwarePair(in directory: URL) -> (code: URL, variables: URL)? {
        let pairs = [
            ("OVMF_CODE.fd", "OVMF_VARS.fd"),
            ("OVMF_CODE_4M.fd", "OVMF_VARS_4M.fd"),
            ("edk2-x86_64-code.fd", "edk2-x86_64-vars.fd"),
            ("edk2-x86_64-code.secboot.fd", "edk2-x86_64-vars.fd"),
        ]
        let requiredNames = Set(pairs.flatMap { [$0.0, $0.1] })
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var candidatesByDirectory: [String: [String: URL]] = [:]
        for case let url as URL in enumerator where requiredNames.contains(url.lastPathComponent) {
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
            let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
            guard resolved.path.hasPrefix(prefix), values?.isRegularFile == true else { continue }
            let parent = resolved.deletingLastPathComponent().path
            candidatesByDirectory[parent, default: [:]][resolved.lastPathComponent] = resolved
        }

        let sortedDirectories = candidatesByDirectory.keys.sorted { lhs, rhs in
            let lhsDepth = lhs.split(separator: "/").count
            let rhsDepth = rhs.split(separator: "/").count
            return lhsDepth == rhsDepth ? lhs < rhs : lhsDepth < rhsDepth
        }
        for (codeName, variablesName) in pairs {
            for parent in sortedDirectories {
                guard let directoryCandidates = candidatesByDirectory[parent],
                      let code = directoryCandidates[codeName],
                      let variables = directoryCandidates[variablesName] else { continue }
                return (code: code, variables: variables)
            }
        }
        return nil
    }

    private static func findUEFIVariables(matching firmware: URL, in directory: URL) -> URL? {
        let variablesName: String
        switch firmware.lastPathComponent {
        case "OVMF_CODE.fd":
            variablesName = "OVMF_VARS.fd"
        case "OVMF_CODE_4M.fd":
            variablesName = "OVMF_VARS_4M.fd"
        case "edk2-x86_64-code.fd", "edk2-x86_64-code.secboot.fd":
            variablesName = "edk2-x86_64-vars.fd"
        default:
            return nil
        }

        // A caller-supplied code image must be paired with the variable store
        // from that exact firmware bundle. A recursive name-only lookup can
        // silently combine unrelated OVMF/EDK2 releases.
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let resolvedFirmware = firmware.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let firmwareValues = try? resolvedFirmware.resourceValues(forKeys: [.isRegularFileKey])
        guard resolvedFirmware.path.hasPrefix(rootPrefix),
              firmwareValues?.isRegularFile == true else { return nil }

        let firmwareDirectory = resolvedFirmware.deletingLastPathComponent().standardizedFileURL
        guard firmwareDirectory.path == root.path || firmwareDirectory.path.hasPrefix(rootPrefix) else {
            return nil
        }
        let candidate = firmwareDirectory.appendingPathComponent(variablesName)
        let resolvedVariables = candidate.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let variablesValues = try? resolvedVariables.resourceValues(forKeys: [.isRegularFileKey])
        guard resolvedVariables.path.hasPrefix(rootPrefix),
              resolvedVariables.deletingLastPathComponent().path == firmwareDirectory.path,
              variablesValues?.isRegularFile == true else { return nil }
        return resolvedVariables
    }

    /// UEFI variable stores are writable guest state. Keep one persistent copy
    /// per VM configuration in Application Support so QEMU never writes into
    /// the signed app bundle or shares NVRAM between different guests.
    private static func makeWritableUEFIVariables(from template: URL, for configurationID: UUID) throws -> URL {
        let values = try template.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values.fileSize ?? 0
        guard size > 0 else { throw RuntimeError.runtimeUnavailable("The bundled UEFI variable-store template is empty.") }
        let modified = Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        let fileManager = FileManager.default
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let directory = supportRoot.appendingPathComponent("AkatsubakiEmu/QEMU/firmware", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let directoryValues = try resolvedDirectory.resourceValues(forKeys: [.isDirectoryKey])
        guard directory.standardizedFileURL.path == resolvedDirectory.path,
              resolvedDirectory.path.hasPrefix(supportRoot.path + "/"),
              directoryValues.isDirectory == true else {
            throw RuntimeError.runtimeUnavailable("The UEFI variable-store directory must remain inside Application Support.")
        }
        let stem = template.deletingPathExtension().lastPathComponent
        let destination = resolvedDirectory.appendingPathComponent("\(stem)-\(configurationID.uuidString)-\(size)-\(modified).fd")
        let destinationValues = try? destination.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
        let destinationIsSymbolicLink = (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) != nil
        let destinationExists = fileManager.fileExists(atPath: destination.path) || destinationIsSymbolicLink
        if destinationValues?.isDirectory == true && !destinationIsSymbolicLink {
            throw RuntimeError.runtimeUnavailable("The UEFI variable-store destination is a directory, not a regular file.")
        }
        let existingFileIsSafe = !destinationIsSymbolicLink
            && destinationValues?.isRegularFile == true
            && destinationValues?.fileSize == size
        if !existingFileIsSafe {
            let temporary = resolvedDirectory.appendingPathComponent("\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: temporary) }
            try fileManager.copyItem(at: template, to: temporary)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if destinationIsSymbolicLink || (destinationExists && destinationValues?.isRegularFile != true) {
                try fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: temporary, to: destination)
            } else if destinationExists {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        }
        // Bundle templates are read-only; the private copy must be writable
        // or QEMU cannot persist the guest's UEFI boot variables.
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    func stop() {
        guard started else { return }
        isteam_qemu_request_stop()
        started = false
        releaseScopesWhenStopped()
    }

    private func releaseScopesWhenStopped() {
        guard isteam_qemu_is_active() else {
            scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            scopedURLs.removeAll()
            return
        }
        // Capture strongly until the native thread exits, even if VMEngine drops
        // its backend after a startup timeout.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) {
            self.releaseScopesWhenStopped()
        }
    }

    var isRunning: Bool { isteam_qemu_is_running() }
    var isActive: Bool { isteam_qemu_is_active() }

    var lastError: String? {
        let message = String(cString: isteam_qemu_last_error())
        return message.isEmpty ? nil : message
    }
}
