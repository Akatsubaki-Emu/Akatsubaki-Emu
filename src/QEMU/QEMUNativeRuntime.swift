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

    func start(configuration: VMConfiguration, diskImage: URL, firmware: URL? = nil) throws {
        guard !started else { return }
        try configuration.validateForStart()
        guard configuration.architecture == .x86_64 else {
            throw RuntimeError.runtimeUnavailable(
                "The bundled QEMU bridge is currently configured for x86_64 guests only."
            )
        }

        #if os(iOS)
        if #available(iOS 17.4, *), JITCoordinator.shared.isStikDebugAvailable,
           !JITCoordinator.shared.isJITReady {
            throw RuntimeError.runtimeUnavailable(
                "QEMU TCG needs executable memory. Enable JIT for Akatsubaki Emu with StikDebug, return to the app, and try again."
            )
        }
        #endif

        let libraryURL: URL
        let dataDirectory: URL
        switch QEMURuntimeStatus.locate() {
        case .unavailable(let reason):
            throw RuntimeError.runtimeUnavailable(reason)
        case .ready(let library, let data):
            libraryURL = library
            dataDirectory = data
        }

        let selectedFirmware: URL?
        if let firmware {
            selectedFirmware = firmware
        } else if configuration.requiresUEFI {
            guard let uefi = Self.findUEFIFirmware(in: dataDirectory) else {
                throw RuntimeError.runtimeUnavailable(
                    "This VM profile requires an x86_64 UEFI code image (OVMF_CODE.fd or edk2-x86_64-code.fd) in the bundled QEMU data directory."
                )
            }
            selectedFirmware = uefi
        } else {
            selectedFirmware = nil
        }

        let selectedFirmwareVariables: URL?
        if selectedFirmware != nil {
            guard let variablesTemplate = Self.findUEFIVariables(in: dataDirectory) else {
                throw RuntimeError.runtimeUnavailable(
                    "UEFI code was found, but no writable variable-store template (OVMF_VARS.fd or edk2-x86_64-vars.fd) is bundled."
                )
            }
            selectedFirmwareVariables = try Self.makeWritableUEFIVariables(from: variablesTemplate, for: configuration.id)
        } else {
            selectedFirmwareVariables = nil
        }

        var newlyScoped: [URL] = []
        for url in [diskImage, selectedFirmware].compactMap({ $0 }) {
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

        let args = QEMUCommandBuilder(configuration: configuration)
            .arguments(diskImage: diskImage, firmware: selectedFirmware,
                       firmwareVariables: selectedFirmwareVariables) + ["-L", dataDirectory.path]
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
                                             libraryPath, error, Int32(errorPointer.count))
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
        EmulationLog.shared.write("QEMU launch requested with disk \(diskImage.lastPathComponent)")
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

    private static func findUEFIFirmware(in directory: URL) -> URL? {
        containedRegularFile(
            named: ["OVMF_CODE.fd", "OVMF_CODE_4M.fd", "edk2-x86_64-code.fd", "edk2-x86_64-code.secboot.fd"],
            in: directory
        )
    }

    private static func findUEFIVariables(in directory: URL) -> URL? {
        containedRegularFile(
            named: ["OVMF_VARS.fd", "OVMF_VARS_4M.fd", "edk2-x86_64-vars.fd"],
            in: directory
        )
    }

    /// UEFI variable stores are writable guest state. Keep one persistent copy
    /// per VM configuration in Application Support so QEMU never writes into
    /// the signed app bundle or shares NVRAM between different guests.
    private static func makeWritableUEFIVariables(from template: URL, for configurationID: UUID) throws -> URL {
        let values = try template.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values.fileSize ?? 0
        guard size > 0 else { throw RuntimeError.runtimeUnavailable("The bundled UEFI variable-store template is empty.") }
        let modified = Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AkatsubakiEmu/QEMU/firmware", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = template.deletingPathExtension().lastPathComponent
        let destination = directory.appendingPathComponent("\(stem)-\(configurationID.uuidString)-\(size)-\(modified).fd")
        let fileManager = FileManager.default
        let existingSize = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if existingSize != size {
            let temporary = directory.appendingPathComponent("\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: temporary) }
            try fileManager.copyItem(at: template, to: temporary)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if fileManager.fileExists(atPath: destination.path) {
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
