import Foundation
import UIKit
import UniformTypeIdentifiers

enum JITMethod: String, CaseIterable {
    case waitForDebugger = "Wait for Debugger"
    case stikDebug = "StikDebug"
    case builtInStikJIT = "Built-in StikJIT"
}

final class JITCoordinator: NSObject, UIDocumentPickerDelegate {
    static let shared = JITCoordinator()
    private override init() { super.init() }

    private weak var presentationController: UIViewController?
    private weak var activeAlert: UIAlertController?
    private var onJITReady: (() -> Void)?
    private var onJITFailure: ((String) -> Void)?
    private var waitingForStikDebugReturn = false
    private var waitingForLocalDevVPN = false
    private var readinessChecksRemaining = 0
    private var readinessCheckScheduled = false
    private var pendingPairingData: Data?
    private var waitingForBuiltInHelperCompletion = false
    private var pairingImportCompletion: (() -> Void)?

    var selectedMethod: JITMethod {
        get {
            JITMethod(rawValue: UserDefaults.standard.string(forKey: "iSteam.jitMethod") ?? "") ?? .stikDebug
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "iSteam.jitMethod")
        }
    }

    var isRunningInLiveContainer: Bool {
        getenv("LC_HOME_PATH") != nil
    }

    var hasGetTaskAllow: Bool {
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        return iSteamJITHasGetTaskAllow()
        #else
        return false
        #endif
    }

    var isStikDebugAvailable: Bool {
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if #available(iOS 17.4, *) {
            return true
        }
        #endif
        return false
    }

    var isJITProtocolSupported: Bool {
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            return iSteamJITIsSupported()
        }
        #endif
        return false
    }

    var isJITProtocolKnown: Bool {
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            return iSteamJITGetProtocolMode() >= 0
        }
        #endif
        return true
    }

    var isJITReady: Bool {
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if #available(iOS 17.4, *) {
            return iSteamJITIsReady()
        }
        #endif
        return false
    }

    var isBuiltInStikJITAvailable: Bool {
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            return !isRunningInLiveContainer
        }
        #endif
        return false
    }

    var hasPairingFile: Bool {
        guard let url = pairingFileURL, let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return false
        }
        return value is [String: Any]
    }

    private var pairingFileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("StikJIT", isDirectory: true)
            .appendingPathComponent("pairingFile.plist")
    }

    func importPairingFile(from controller: UIViewController, completion: (() -> Void)? = nil) {
        guard isBuiltInStikJITAvailable else {
            presentationController = controller
            show("Built-in StikJIT requires iOS 26 or later on a physical device and is unavailable inside LiveContainer.", title: "Built-in JIT unavailable")
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.propertyList, .data], asCopy: true)
        picker.delegate = self
        pairingImportCompletion = completion
        presentationController = controller
        controller.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let source = urls.first, let destination = pairingFileURL else { return }
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed { source.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: source)
            let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard propertyList is [String: Any] else {
                throw NSError(domain: "AkatsubakiStikJIT", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The pairing file must contain a property-list dictionary."])
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            let completion = pairingImportCompletion
            pairingImportCompletion = nil
            completion?()
            show("The device pairing file is stored in Documents/StikJIT/pairingFile.plist. Its contents are not logged.", title: "Pairing file imported")
        } catch {
            show("Could not import the pairing file: \(error.localizedDescription)", title: "Pairing file error")
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pairingImportCompletion = nil
    }

    func requestJIT(from controller: UIViewController?, onFailure: ((String) -> Void)? = nil, onReady: (() -> Void)? = nil) {
        presentationController = controller
        onJITReady = onReady
        onJITFailure = onFailure
        guard isStikDebugAvailable else {
            failRequest("StikDebug JIT requires iOS 17.4 or later on a physical iOS device.", title: "JIT unavailable")
            return
        }
        guard hasGetTaskAllow else {
            failRequest("This installation does not have the get-task-allow entitlement. Reinstall Akatsubaki Emu with a signing method that preserves this entitlement, then try again.", title: "JIT signing required")
            return
        }
        guard isJITProtocolKnown else {
            failRequest("Akatsubaki Emu cannot identify this device's iOS 26 JIT protocol. Update the app before starting a VM.", title: "JIT compatibility unknown")
            return
        }
        guard !isJITReady else {
            completeJITRequest()
            return
        }

        switch selectedMethod {
        case .waitForDebugger:
            waitingForStikDebugReturn = true
            readinessChecksRemaining = 30
            show("Waiting for a compatible debugger to attach. Return to Akatsubaki Emu after enabling JIT.", title: "Waiting for debugger")
            checkReadiness()
        case .stikDebug:
            enableLocalDevVPN()
        case .builtInStikJIT:
            guard isBuiltInStikJITAvailable else {
                failRequest("Built-in StikJIT requires iOS 26 or later on a physical device and cannot run inside LiveContainer. Choose StikDebug or Wait for Debugger instead.", title: "Built-in JIT unavailable")
                return
            }
            guard hasPairingFile, let pairingURL = pairingFileURL,
                  let data = try? Data(contentsOf: pairingURL) else {
                failRequest("Import a valid device pairing file in Settings → JIT before using Built-in StikJIT.", title: "Pairing file required")
                return
            }
            pendingPairingData = data
            enableLocalDevVPN()
        }
    }

    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard url.scheme == Bundle.main.bundleIdentifier, waitingForLocalDevVPN else { return false }
        waitingForLocalDevVPN = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.continueAfterVPN()
        }
        return true
    }

    private func continueAfterVPN() {
        switch selectedMethod {
        case .stikDebug:
            openStikDebug()
        case .builtInStikJIT:
            startBuiltInStikJIT()
        case .waitForDebugger:
            failRequest("The selected JIT method does not use LocalDevVPN.", title: "JIT request failed")
        }
    }

    func applicationDidBecomeActive() {
        guard waitingForStikDebugReturn else { return }
        readinessChecksRemaining = max(readinessChecksRemaining, waitingForBuiltInHelperCompletion ? 300 : 30)
        checkReadiness()
    }

    private func enableLocalDevVPN() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            failRequest("Could not determine Akatsubaki Emu's bundle identifier.", title: "JIT request failed")
            return
        }
        guard let probeURL = URL(string: "localdevvpn://"),
              UIApplication.shared.canOpenURL(probeURL) else {
            failRequest("Install LocalDevVPN and open it once to configure its VPN profile. Akatsubaki Emu will then start the tunnel automatically when JIT is requested.", title: "LocalDevVPN required")
            return
        }

        var components = URLComponents()
        components.scheme = "localdevvpn"
        components.host = "enable"
        components.queryItems = [URLQueryItem(name: "scheme", value: bundleID)]
        guard let vpnURL = components.url else {
            failRequest("Could not create the LocalDevVPN activation URL.", title: "JIT request failed")
            return
        }

        waitingForLocalDevVPN = true
        UIApplication.shared.open(vpnURL, options: [:]) { [weak self] opened in
            guard let self, !opened else { return }
            self.waitingForLocalDevVPN = false
            self.failRequest("LocalDevVPN could not be opened. Install it and approve its VPN configuration before requesting JIT.", title: "VPN unavailable")
        }
    }

    private func startBuiltInStikJIT() {
        #if os(iOS)
        guard #available(iOS 26.0, *), isBuiltInStikJITAvailable,
              let pairingData = pendingPairingData else {
            failRequest("Built-in StikJIT is unavailable or the pairing file could not be read.", title: "Built-in JIT unavailable")
            return
        }
        pendingPairingData = nil
        waitingForStikDebugReturn = true
        waitingForBuiltInHelperCompletion = true
        readinessChecksRemaining = 300
        show("Preparing the device and Developer Disk Image. Keep Akatsubaki open. Once StikJIT attaches, QEMU starts and completes the universal TXM breakpoint handshake.", title: "Built-in StikJIT")
        AkatsubakiJITHelperCoordinator.enableJIT(targetPID: getpid(), pairingData: pairingData) { [weak self] success, message in
            guard let self else { return }
            self.waitingForBuiltInHelperCompletion = false
            guard success else {
                self.failRequest("Built-in StikJIT failed: \(message)", title: "Built-in JIT failed")
                return
            }
            if self.waitingForStikDebugReturn {
                self.checkReadiness()
            } else {
                self.onJITFailure = nil
            }
        }
        checkReadiness()
        #else
        failRequest("Built-in StikJIT is only available on physical iOS devices.", title: "Built-in JIT unavailable")
        #endif
    }

    private func openStikDebug() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            failRequest("Could not determine Akatsubaki Emu's bundle identifier.", title: "JIT request failed")
            return
        }

        var components = URLComponents()
        components.scheme = "stikdebug"
        components.host = "enable-jit"
        var queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleID),
            URLQueryItem(name: "pid", value: String(getpid()))
        ]
        if #available(iOS 26.0, *), isJITProtocolSupported {
            queryItems.append(URLQueryItem(name: "script-name", value: "universal.js"))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            failRequest("Could not create the StikDebug request URL.", title: "JIT request failed")
            return
        }

        waitingForStikDebugReturn = true
        readinessChecksRemaining = 30
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            guard let self else { return }
            guard !opened else { return }
            self.failRequest("StikDebug could not be opened. Install StikDebug, import this device's pairing file into it, and try again.", title: "StikDebug unavailable")
        }
    }

    private func checkReadiness() {
        guard waitingForStikDebugReturn, !readinessCheckScheduled else { return }
        if isJITReady {
            completeJITRequest()
            return
        }
        guard readinessChecksRemaining > 0 else {
            let detail = selectedMethod == .builtInStikJIT
                ? "JIT was not confirmed. Check LocalDevVPN connectivity, the imported pairing file, Developer Mode, get-task-allow signing, and the built-in helper's error status. No emulation workload was started."
                : "JIT was not confirmed. Check that LocalDevVPN has started, StikDebug has a valid pairing file, Developer Mode is enabled, and this app was signed with get-task-allow. If using LiveContainer, enable Use LiveContainer's Bundle ID. No emulation workload was started."
            failRequest(detail, title: "JIT not confirmed")
            return
        }
        guard UIApplication.shared.applicationState == .active else { return }

        readinessChecksRemaining -= 1
        readinessCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.readinessCheckScheduled = false
            self.checkReadiness()
        }
    }

    private func completeJITRequest() {
        waitingForStikDebugReturn = false
        waitingForLocalDevVPN = false
        readinessChecksRemaining = 0
        readinessCheckScheduled = false
        let completion = onJITReady
        onJITReady = nil
        if !waitingForBuiltInHelperCompletion {
            onJITFailure = nil
        }
        dismissActiveAlert { [weak self] in
            if let completion {
                completion()
            } else {
                self?.show("JIT is enabled for this process. You can now launch your emulation session.", title: "JIT ready")
            }
        }
    }

    private func failRequest(_ message: String, title: String) {
        waitingForStikDebugReturn = false
        waitingForLocalDevVPN = false
        readinessChecksRemaining = 0
        readinessCheckScheduled = false
        pendingPairingData = nil
        let cancelHelper = waitingForBuiltInHelperCompletion
        waitingForBuiltInHelperCompletion = false
        #if os(iOS)
        if cancelHelper, #available(iOS 26.0, *) {
            AkatsubakiJITHelperCoordinator.cancel()
        }
        #endif
        let failure = onJITFailure
        onJITFailure = nil
        onJITReady = nil
        failure?(message)
        show(message, title: title)
    }

    private func dismissActiveAlert(completion: (() -> Void)? = nil) {
        guard let alert = activeAlert else {
            completion?()
            return
        }
        activeAlert = nil
        guard alert.presentingViewController != nil else {
            completion?()
            return
        }
        alert.dismiss(animated: false, completion: completion)
    }

    private func show(_ message: String, title: String) {
        guard let controller = presentationController,
              controller.viewIfLoaded?.window != nil else { return }
        dismissActiveAlert { [weak self, weak controller] in
            guard let self, let controller, controller.viewIfLoaded?.window != nil else { return }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self.activeAlert = alert
            controller.present(alert, animated: true)
        }
    }
}
