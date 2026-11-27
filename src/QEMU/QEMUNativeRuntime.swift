import Foundation

/// Owns one native QEMU session and keeps any Files-provider security scopes
/// alive for the full lifetime of QEMU (not just while constructing argv).
final class QEMUNativeRuntime {
    static let shared = QEMUNativeRuntime()
    enum RuntimeError: LocalizedError {
        case runtimeUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .runtimeUnavailable(let message): return message
            }
        }
    }

    private let stateLock = NSLock()
    private(set) var started = false
    private(set) var isPaused = false
    private var sessionKey: String?
    private var sessionGeneration: UInt64 = 0
    private var controlError: String?
    private var scopedURLs: [URL] = []
    private var nativeSessionEnded = false
    private var nativeLifecycleMonitor: DispatchSourceTimer?
    private var powerDownRequestedGeneration: UInt64?

    private init() {}

    /// Observe the native worker independently of any display controller so
    /// security-scoped files are released even if the user leaves the VM UI.
    private func startNativeLifecycleMonitoringLocked() {
        guard nativeLifecycleMonitor == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.refreshCompletedSessionLocked()
            self.stateLock.unlock()
        }
        nativeLifecycleMonitor = timer
        timer.resume()
    }

    /// Must be called with stateLock held. The native worker clears its active
    /// flag only after qemu_cleanup has returned.
    private func refreshCompletedSessionLocked() {
        guard started, !nativeSessionEnded, !isteam_qemu_is_active() else { return }
        nativeSessionEnded = true
        powerDownRequestedGeneration = nil
        isPaused = false
        let retainedURLs = scopedURLs
        scopedURLs.removeAll(keepingCapacity: false)
        retainedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        try? FileManager.default.removeItem(atPath: QEMUCommandBuilder.qmpSocketPath)
        EmulationLog.shared.write(
            "QEMU native cleanup completed; released \(retainedURLs.count) security-scoped file access lease(s). "
            + "Relaunch Akatsubaki Emu before starting another guest."
        )
        nativeLifecycleMonitor?.cancel()
        nativeLifecycleMonitor = nil
    }

    @discardableResult
    func start(configuration: VMConfiguration, diskImage: URL, writableDiskImage: URL? = nil,
               firmware: URL? = nil) throws -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        try configuration.validateForStart()
        refreshCompletedSessionLocked()
        guard !nativeSessionEnded else {
            throw RuntimeError.runtimeUnavailable(
                "The previous QEMU process has exited. Relaunch Akatsubaki Emu before starting another guest."
            )
        }
        guard configuration.architecture == .x86_64 else {
            throw RuntimeError.runtimeUnavailable(
                "The bundled QEMU bridge is currently configured for x86_64 guests only."
            )
        }

        let requestedJIT = configuration.accelerator == .jit
        let allowsTCIFallback = RuntimeSettings.shared.acceleration.allowsTCIFallback
        var effectiveConfiguration = configuration
        var requiresJIT = requestedJIT
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if requiresJIT && !JITCoordinator.shared.isQEMUJITReady {
            guard allowsTCIFallback else {
                throw RuntimeError.runtimeUnavailable(
                    "QEMU JIT was explicitly selected but is unavailable. Choose Automatic to allow TCI fallback or select QEMU TCI directly."
                )
            }
            requiresJIT = false
            effectiveConfiguration.accelerator = .tcg
            EmulationLog.shared.write("QEMU JIT is unavailable; falling back to the TCI no-JIT runtime.")
        }
        #endif

        var runtimeStatus = QEMURuntimeStatus.inspect(requiresJIT: requiresJIT)
        if requiresJIT, case .unavailable(let reason) = runtimeStatus {
            guard allowsTCIFallback else {
                throw RuntimeError.runtimeUnavailable(
                    "The selected QEMU JIT runtime is unavailable: \(reason). Choose Automatic to allow TCI fallback or select QEMU TCI directly."
                )
            }
            // A missing or unloadable JIT variant must not block a packaged
            // no-JIT interpreter runtime. Re-run the full TCI loadability probe.
            requiresJIT = false
            effectiveConfiguration.accelerator = .tcg
            EmulationLog.shared.write("QEMU JIT is unavailable; falling back to the TCI no-JIT runtime.")
            runtimeStatus = QEMURuntimeStatus.inspect(requiresJIT: false)
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

        effectiveConfiguration.accelerator = requiresJIT ? .jit : .tcg
        let requestedSessionKey = Self.makeSessionKey(
            configuration: effectiveConfiguration, diskImage: diskImage,
            writableDiskImage: writableDiskImage, firmware: selectedFirmware,
            firmwareVariables: selectedFirmwareVariables, library: libraryURL,
            dataDirectory: dataDirectory, requiresJIT: requiresJIT
        )
        if started {
            guard sessionKey == requestedSessionKey else {
                throw RuntimeError.runtimeUnavailable(
                    "The in-process QEMU runtime is already bound to another VM configuration. Restart Akatsubaki Emu to switch guests."
                )
            }
            guard isPaused else {
                throw RuntimeError.runtimeUnavailable(
                    "A QEMU guest is already running. Duplicate active starts are rejected."
                )
            }
            let resumed = Self.sendQMP("cont")
            let alreadyRunning = resumed.error?.localizedCaseInsensitiveContains("already running") == true
            guard resumed.success || alreadyRunning else {
                controlError = resumed.error
                throw RuntimeError.runtimeUnavailable(resumed.error ?? "QEMU did not acknowledge cont.")
            }
            isPaused = false
            controlError = nil
            EmulationLog.shared.write("QEMU guest resumed through the persistent QMP session.")
            return advanceSessionGeneration()
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

        EmulationLog.shared.write("QEMU effective accelerator: \(requiresJIT ? "JIT" : "TCI")")
        guard QEMUCommandBuilder.qmpSocketPath.utf8.count < 104 else {
            // Release every security-scoped URL acquired above before this
            // early startup failure. They are not yet owned by scopedURLs.
            newlyScoped.forEach { $0.stopAccessingSecurityScopedResource() }
            throw RuntimeError.runtimeUnavailable(
                "The app temporary directory produces a QMP socket path that exceeds the AF_UNIX sun_path limit."
            )
        }
        try? FileManager.default.removeItem(atPath: QEMUCommandBuilder.qmpSocketPath)
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
        sessionKey = requestedSessionKey
        started = true
        isPaused = false
        controlError = nil
        startNativeLifecycleMonitoringLocked()
        EmulationLog.shared.write("QEMU launch requested with boot media \(diskImage.lastPathComponent)"
            + (writableDiskImage.map { " and writable disk \($0.lastPathComponent)" } ?? ""))
        return advanceSessionGeneration()
    }

    private func advanceSessionGeneration() -> UInt64 {
        sessionGeneration &+= 1
        if sessionGeneration == 0 { sessionGeneration = 1 }
        return sessionGeneration
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

    @discardableResult
    func reset(sessionGeneration expected: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        refreshCompletedSessionLocked()
        guard started, !nativeSessionEnded else {
            controlError = "QEMU runtime is not active; relaunch Akatsubaki Emu before starting another guest."
            return false
        }
        guard expected == sessionGeneration else { return false }
        let result = Self.sendQMP("system_reset")
        guard result.success else {
            controlError = result.error ?? "QEMU did not acknowledge system_reset."
            EmulationLog.shared.write("QEMU reset failed: \(controlError ?? "unknown QMP error")")
            return false
        }
        if isPaused {
            let resumed = Self.sendQMP("cont")
            let alreadyRunning = resumed.error?.localizedCaseInsensitiveContains("already running") == true
            guard resumed.success || alreadyRunning else {
                controlError = resumed.error ?? "QEMU did not acknowledge cont after reset."
                EmulationLog.shared.write("QEMU reset resume failed: \(controlError ?? "unknown QMP error")")
                return false
            }
        }
        isPaused = false
        controlError = nil
        EmulationLog.shared.write("QEMU guest reset through the persistent QMP session.")
        return true
    }

    @discardableResult
    func stop(sessionGeneration expected: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        refreshCompletedSessionLocked()
        guard started, !nativeSessionEnded else { return true }
        guard expected == sessionGeneration else { return true }
        guard !isPaused else { return true }
        let result = Self.sendQMP("stop")
        let alreadyStopped = result.error?.localizedCaseInsensitiveContains("already stopped") == true
            || result.error?.localizedCaseInsensitiveContains("not running") == true
        guard result.success || alreadyStopped else {
            controlError = result.error ?? "QEMU did not acknowledge the pause request."
            EmulationLog.shared.write("QEMU pause failed: \(controlError ?? "unknown QMP error")")
            return false
        }
        isPaused = true
        controlError = nil
        EmulationLog.shared.write("QEMU guest paused; the process and disk scopes remain available for the next launch.")
        return true
    }

    /// Gives the guest OS 120 seconds to handle the ACPI power-button event.
    /// If the guest ignores ACPI, a controlled QMP quit ensures native cleanup.
    @discardableResult
    func requestGuestPowerDown(sessionGeneration expected: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        refreshCompletedSessionLocked()
        guard started, !nativeSessionEnded, expected == sessionGeneration, !isPaused,
              powerDownRequestedGeneration == nil else {
            controlError = "The active QEMU guest session is not available for power-down."
            return false
        }
        let result = Self.sendQMP("system_powerdown")
        guard result.success else {
            controlError = result.error ?? "QEMU did not acknowledge the ACPI power-button request."
            EmulationLog.shared.write("QEMU guest power-down request failed: \(controlError ?? "unknown QMP error")")
            return false
        }
        powerDownRequestedGeneration = expected
        controlError = nil
        EmulationLog.shared.write("Sent an ACPI power-button event; waiting up to 120 seconds for guest shutdown.")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(120)) { [weak self] in
            self?.forceQuitAfterPowerDown(sessionGeneration: expected)
        }
        return true
    }

    private func forceQuitAfterPowerDown(sessionGeneration expected: UInt64) {
        stateLock.lock()
        let shouldQuit = started && !nativeSessionEnded
            && sessionGeneration == expected
            && powerDownRequestedGeneration == expected
        stateLock.unlock()
        guard shouldQuit else { return }

        EmulationLog.shared.write("Guest did not complete ACPI shutdown within 120 seconds; requesting controlled QEMU quit.")
        let result = Self.sendQMP("quit")
        if !result.success && isteam_qemu_is_active() {
            // Last-resort native shutdown request if the QMP socket is unavailable.
            isteam_qemu_request_stop()
        }
    }

    private static func sendQMP(_ command: String) -> (success: Bool, error: String?) {
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let success = QEMUCommandBuilder.qmpSocketPath.withCString { socketPath in
            command.withCString { commandPointer in
                errorBuffer.withUnsafeMutableBufferPointer { buffer -> Bool in
                    guard let error = buffer.baseAddress else { return false }
                    return isteam_qemu_qmp_command(socketPath, commandPointer, error, Int32(buffer.count))
                }
            }
        }
        let message = String(cString: errorBuffer)
        return (success, message.isEmpty ? nil : message)
    }

    private static func makeSessionKey(configuration: VMConfiguration, diskImage: URL,
                                       writableDiskImage: URL?, firmware: URL?,
                                       firmwareVariables: URL?, library: URL,
                                       dataDirectory: URL, requiresJIT: Bool) -> String {
        let resolvedPath: (URL?) -> String = { url in
            guard let url else { return "" }
            return url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return [
            String(describing: configuration), configuration.id.uuidString,
            resolvedPath(diskImage), resolvedPath(writableDiskImage),
            resolvedPath(firmware), resolvedPath(firmwareVariables),
            resolvedPath(library), resolvedPath(dataDirectory),
            requiresJIT ? "jit" : "tcg"
        ].joined(separator: "\u{0}")
    }

    var isRunning: Bool {
        stateLock.lock()
        refreshCompletedSessionLocked()
        let guestShouldRun = started && !nativeSessionEnded && !isPaused
        stateLock.unlock()
        return guestShouldRun && isteam_qemu_is_running()
    }

    var isActive: Bool {
        stateLock.lock()
        refreshCompletedSessionLocked()
        let active = started && !nativeSessionEnded && isteam_qemu_is_active()
        stateLock.unlock()
        return active
    }

    func isRunning(sessionGeneration expected: UInt64?) -> Bool {
        stateLock.lock()
        refreshCompletedSessionLocked()
        let ownsRunningSession = expected == sessionGeneration && expected != nil
            && started && !nativeSessionEnded && !isPaused
        stateLock.unlock()
        return ownsRunningSession && isteam_qemu_is_running()
    }

    func isActive(sessionGeneration expected: UInt64?) -> Bool {
        stateLock.lock()
        refreshCompletedSessionLocked()
        let ownsActiveSession = expected == sessionGeneration && expected != nil
            && started && !nativeSessionEnded
        stateLock.unlock()
        return ownsActiveSession && isteam_qemu_is_active()
    }

    func lastError(sessionGeneration expected: UInt64?) -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard expected == sessionGeneration, expected != nil else { return nil }
        if let controlError { return controlError }
        let message = String(cString: isteam_qemu_last_error())
        return message.isEmpty ? nil : message
    }

    var lastError: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let controlError { return controlError }
        let message = String(cString: isteam_qemu_last_error())
        return message.isEmpty ? nil : message
    }
}
