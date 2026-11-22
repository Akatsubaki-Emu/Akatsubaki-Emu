import Foundation

/// Locates the UTM-built QEMU dynamic library and companion data directory.
/// The packaging workflow writes the exact library path because UTM changes
/// library names/layout between revisions. The bridge performs an explicit load/dependency/export probe before reporting ready.
enum QEMURuntimeStatus {
    case unavailable(String)
    case ready(libraryURL: URL, dataDirectory: URL)

    static func inspect(bundle: Bundle = .main, requiresJIT: Bool = true) -> QEMURuntimeStatus {
        switch locate(bundle: bundle, requiresJIT: requiresJIT) {
        case .unavailable(let reason): return .unavailable(reason)
        case .ready(let libraryURL, let dataDirectory):
            return validateLoadableLibrary(libraryURL, dataDirectory: dataDirectory,
                                            requiresJIT: requiresJIT)
        }
    }

    static func locate(bundle: Bundle = .main, requiresJIT: Bool = true) -> QEMURuntimeStatus {
        let fm = FileManager.default
        let bundleRoot = bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let bundlePrefix = bundleRoot.path.hasSuffix("/") ? bundleRoot.path : bundleRoot.path + "/"
        let qemuRoot = bundle.bundleURL.appendingPathComponent("QEMU", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let modeDirectory = qemuRoot.appendingPathComponent(requiresJIT ? "JIT" : "TCI", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        var dataDirectory = modeDirectory
        var dataIsDirectory: ObjCBool = false
        if !fm.fileExists(atPath: dataDirectory.path, isDirectory: &dataIsDirectory), requiresJIT {
            // Older releases stored the JIT data directly in QEMU/.
            dataDirectory = qemuRoot
            dataIsDirectory = ObjCBool(false)
        }
        guard dataDirectory.path.hasPrefix(bundlePrefix),
              fm.fileExists(atPath: dataDirectory.path, isDirectory: &dataIsDirectory),
              dataIsDirectory.boolValue else {
            return .unavailable(requiresJIT
                ? "The QEMU JIT data directory is missing or unsafe in the app bundle."
                : "The no-JIT QEMU TCI runtime is not packaged. Build and embed the ios-tci-arm64 runtime.")
        }

        func validatedRegularLibrary(_ candidate: URL) -> URL? {
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
            let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
            guard resolved.path.hasPrefix(bundlePrefix),
                  values?.isRegularFile == true else { return nil }
            return resolved
        }

        // Prefer the build-generated manifest. Resolve it before reading so a
        // bundle symlink cannot redirect manifest inspection outside the bundle.
        let dataPrefix = dataDirectory.path.hasSuffix("/") ? dataDirectory.path : dataDirectory.path + "/"
        let manifest = dataDirectory.appendingPathComponent("runtime-library-path.txt")
            .resolvingSymlinksInPath().standardizedFileURL
        let manifestValues = try? manifest.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if manifest.path.hasPrefix(dataPrefix),
           manifestValues?.isRegularFile == true,
           let manifestSize = manifestValues?.fileSize, manifestSize <= 4096,
           let rawPath = try? String(contentsOf: manifest, encoding: .utf8) {
            let relativePath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !relativePath.isEmpty,
               !relativePath.hasPrefix("/"),
               !relativePath.contains("\\"),
               !relativePath.split(separator: "/").contains(".."),
               !relativePath.split(separator: "/").contains(".") {
                if let library = validatedRegularLibrary(bundle.bundleURL.appendingPathComponent(relativePath)) {
                    return .ready(libraryURL: library, dataDirectory: dataDirectory)
                }
            }
        }

        // Backward-compatible fallback for previously packaged runtime artifacts.
        let frameworks = bundle.privateFrameworksURL
        var candidates = (requiresJIT ? [
            frameworks?.appendingPathComponent("QEMU.framework/QEMU"),
            frameworks?.appendingPathComponent("libqemu-system-x86_64.dylib"),
            frameworks?.appendingPathComponent("qemu-x86_64-softmmu"),
            frameworks?.appendingPathComponent("qemu-x86_64-softmmu.dylib"),
            bundle.bundleURL.appendingPathComponent("QEMU/libqemu-system-x86_64.dylib")
        ] : [
            frameworks?.appendingPathComponent("QEMU-TCI.framework/QEMU"),
            frameworks?.appendingPathComponent("libqemu-system-x86_64-tci.dylib"),
            frameworks?.appendingPathComponent("qemu-x86_64-softmmu-tci")
        ]).compactMap { $0 }

        if let frameworks,
           let enumerator = fm.enumerator(
                at: frameworks,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
           ) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent.lowercased()
                let path = url.path.lowercased()
                let isTCIArtifact = name.contains("-tci")
                    || path.contains("/tci/")
                    || path.contains("/qemu-tci.framework/")
                let isRuntimeLibrary = name.contains("qemu-x86_64-softmmu")
                    || name == "libqemu-system-x86_64.dylib"
                    || (name == "qemu" && (
                        path.contains("/qemu.framework/")
                            || path.contains("/qemu-tci.framework/")
                    ))
                if isRuntimeLibrary && (requiresJIT ? !isTCIArtifact : isTCIArtifact) {
                    candidates.append(url)
                }
            }
        }

        guard let library = candidates.compactMap(validatedRegularLibrary).first else {
            return .unavailable(requiresJIT
                ? "No embedded x86_64 QEMU JIT device library was found. Run the UTM runtime packaging workflow and code-sign nested code."
                : "No embedded x86_64 QEMU TCI device library was found. Build the ios-tci-arm64 runtime and embed its TCI framework and data.")
        }
        return .ready(libraryURL: library, dataDirectory: dataDirectory)
    }

    /// A file's existence is not proof that it is a usable runtime. dlopen with
    /// RTLD_NOW checks the device loader, code signature and transitive dylibs;
    /// dlsym verifies the lifecycle exports required by our native bridge.
    /// This does not boot a guest or prove firmware/device support.
    private static func validateLoadableLibrary(_ library: URL,
                                                dataDirectory: URL,
                                                requiresJIT: Bool) -> QEMURuntimeStatus {
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let valid = library.path.withCString { libraryPath in
            errorBuffer.withUnsafeMutableBufferPointer { buffer -> Bool in
                guard let baseAddress = buffer.baseAddress else { return false }
                return isteam_qemu_validate_library(
                    libraryPath, requiresJIT, baseAddress, Int32(buffer.count)
                )
            }
        }
        guard valid else {
            let message = String(cString: errorBuffer)
            return .unavailable(message.isEmpty
                ? "The bundled QEMU library failed its load/export validation."
                : message)
        }
        return .ready(libraryURL: library, dataDirectory: dataDirectory)
    }

    static var diagnostic: String {
        switch inspect() {
        case .unavailable(let reason): return reason
        case .ready(let libraryURL, let dataDirectory):
            return "QEMU library located at \(libraryURL.path); data at \(dataDirectory.path). The bridge load/dependency/export probe passed; guest boot is not verified."
        }
    }
}
