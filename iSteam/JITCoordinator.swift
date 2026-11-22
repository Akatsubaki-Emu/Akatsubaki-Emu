import Foundation
import UIKit

enum JITMethod: String, CaseIterable {
    case builtInStikJIT = "Built-in StikJIT"
    case waitForDebugger = "Wait for Debugger"
    case stikDebug = "StikDebug"
}

final class JITCoordinator {
    static let shared = JITCoordinator()
    private init() {}

    private weak var presentationController: UIViewController?
    private var onJITReady: (() -> Void)?
    private var onJITFailure: ((String) -> Void)?
    private var waitingForStikDebugReturn = false
    private var waitingForLocalDevVPN = false
    private var readinessChecksRemaining = 0
    private var readinessCheckScheduled = false
    private var activeMethod: JITMethod = .stikDebug
    private var pendingPairingData: Data?

    var selectedMethod: JITMethod {
        get {
            JITMethod(rawValue: UserDefaults.standard.string(forKey: "iSteam.jitMethod") ?? "") ?? (isBuiltInStikJITAvailable ? .builtInStikJIT : .stikDebug)
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

    var isBuiltInStikJITAvailable: Bool {
#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *), !isRunningInLiveContainer { return true }
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

    func requestJIT(from controller: UIViewController?, onFailure: ((String) -> Void)? = nil, onReady: (() -> Void)? = nil) {
        presentationController = controller
        onJITReady = onReady
        onJITFailure = onFailure
        activeMethod = selectedMethod

        guard isStikDebugAvailable else {
            failRequest("JIT is unavailable for this device or installation.", title: "JIT unavailable")
            return
        }
        guard hasGetTaskAllow else {
            failRequest("This installation does not have the get-task-allow entitlement required for JIT.", title: "JIT signing required")
            return
        }
        if !isJITProtocolKnown && activeMethod != .builtInStikJIT {
            failRequest("The TXM protocol is unknown. External JIT methods remain disabled until the bundled StikJIT helper identifies the device.", title: "JIT compatibility unknown")
            return
        }
        if activeMethod == .builtInStikJIT && !isBuiltInStikJITAvailable {
            failRequest("Bundled StikJIT requires iOS 26 or later and a direct app installation.", title: "JIT unavailable")
            return
        }
        guard !isJITReady else { completeJITRequest(); return }

        switch activeMethod {
        case .builtInStikJIT:
#if os(iOS)
            guard #available(iOS 26.0, *) else {
                failRequest("Bundled StikJIT requires iOS 26 or later.", title: "JIT unavailable")
                return
            }
            do {
                pendingPairingData = try StikJITPairingFileStore.load()
            } catch {
                failRequest("Import your device pairing file in Settings → Built-in JIT. " + error.localizedDescription, title: "Pairing file required")
                return
            }
            enableLocalDevVPN()
#else
            failRequest("Bundled StikJIT is only available on iOS.", title: "JIT unavailable")
#endif
        case .waitForDebugger:
            waitingForStikDebugReturn = true
            readinessChecksRemaining = 30
            show("Waiting for a compatible debugger to attach. Return to Akatsubaki Emu after enabling JIT.", title: "Waiting for debugger")
        case .stikDebug:
            enableLocalDevVPN()
        }
    }

    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard url.scheme == Bundle.main.bundleIdentifier, waitingForLocalDevVPN else { return false }
        waitingForLocalDevVPN = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            switch self.activeMethod {
            case .stikDebug:
                self.openStikDebug()
            case .builtInStikJIT:
#if os(iOS)
                if #available(iOS 26.0, *), self.isBuiltInStikJITAvailable {
                    self.startBuiltInStikJIT()
                } else {
                    self.failRequest("Bundled StikJIT is not available on this device.", title: "JIT unavailable")
                }
#else
                self.failRequest("Bundled StikJIT is only available on iOS.", title: "JIT unavailable")
#endif
            case .waitForDebugger:
                self.failRequest("The Wait for Debugger method does not use LocalDevVPN.", title: "JIT configuration error")
            }
        }
        return true
    }

    func applicationDidBecomeActive() {
        guard waitingForStikDebugReturn else { return }
        readinessChecksRemaining = max(readinessChecksRemaining, activeMethod == .builtInStikJIT ? 1200 : 30)
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

#if os(iOS)
    @available(iOS 26.0, *)
    private func startBuiltInStikJIT() {
        guard let pairingData = pendingPairingData else {
            failRequest("The StikJIT pairing file is missing. Import it in Settings → Built-in JIT.", title: "Pairing file required")
            return
        }
        pendingPairingData = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let prepared = try await BuiltInJITHelperClient.shared.perform(AkatsubakiJITHelperRequest.prepare(pairingData))
                guard prepared.state == .completed else {
                    self.failRequest(prepared.message, title: "StikJIT preparation failed")
                    return
                }
                let forceRequested = UserDefaults.standard.bool(forKey: "iSteam.jitForceScript")
                let protocolMode: Int32
                let forceScript: Bool
                if let txmPresent = prepared.txmPresent {
                    protocolMode = txmPresent ? 1 : 0
                    forceScript = false
                } else {
                    guard forceRequested else {
                        self.failRequest("StikJIT could not determine TXM presence. Enable Force JIT Script in Settings → Built-in JIT only if you accept the TXM breakpoint fallback.", title: "TXM detection unknown")
                        return
                    }
                    protocolMode = 1
                    forceScript = true
                }
                iSteamJITSetProtocolOverride(protocolMode)
                let response = try await BuiltInJITHelperClient.shared.send(
                    AkatsubakiJITHelperRequest.enableJIT(targetPID: Int32(getpid()), pairingData: pairingData, forceScript: forceScript)
                )
                guard response.accepted else {
                    self.failRequest(response.message, title: "StikJIT failed")
                    return
                }
                self.waitingForStikDebugReturn = true
                self.readinessChecksRemaining = 1200
                self.checkReadiness()
            } catch {
                self.failRequest("Bundled StikJIT helper failed: " + error.localizedDescription, title: "JIT failed")
            }
        }
    }
#endif

    private func checkReadiness() {
        guard waitingForStikDebugReturn, !readinessCheckScheduled else { return }
        if isJITReady { completeJITRequest(); return }
        guard readinessChecksRemaining > 0 else {
            failRequest("JIT was not confirmed. Check LocalDevVPN, pairing, Developer Mode and the Developer Disk Image.", title: "JIT not confirmed")
            return
        }
        guard UIApplication.shared.applicationState == .active else { return }
        readinessChecksRemaining -= 1
        if activeMethod == .builtInStikJIT {
#if os(iOS)
            readinessCheckScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let status = try await BuiltInJITHelperClient.shared.send(.status)
                    self.readinessCheckScheduled = false
                    if status.state == .failed {
                        self.failRequest(status.message, title: "StikJIT failed")
                        return
                    }
                    self.scheduleReadinessCheck()
                } catch {
                    self.readinessCheckScheduled = false
                    self.failRequest("The embedded StikJIT helper stopped responding: " + error.localizedDescription, title: "JIT helper interrupted")
                }
            }
#else
            failRequest("Bundled StikJIT is only available on iOS.", title: "JIT unavailable")
#endif
            return
        }
        scheduleReadinessCheck()
    }

    private func scheduleReadinessCheck() {
        guard !readinessCheckScheduled else { return }
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
        onJITFailure = nil
        if let completion {
            completion()
        } else {
            show("JIT is enabled for this process. You can now launch your emulation session.", title: "JIT ready")
        }
    }

    private func failRequest(_ message: String, title: String) {
        pendingPairingData = nil
        iSteamJITSetProtocolOverride(-1)
#if os(iOS)
        if activeMethod == .builtInStikJIT {
            Task { @MainActor in BuiltInJITHelperClient.shared.invalidate() }
        }
#endif

        waitingForStikDebugReturn = false
        waitingForLocalDevVPN = false
        readinessChecksRemaining = 0
        readinessCheckScheduled = false
        let failure = onJITFailure
        onJITFailure = nil
        onJITReady = nil
        failure?(message)
        show(message, title: title)
    }

    private func show(_ message: String, title: String) {
        guard let controller = presentationController,
              controller.viewIfLoaded?.window != nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        controller.present(alert, animated: true)
    }
}
