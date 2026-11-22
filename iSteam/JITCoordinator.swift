import Foundation
import UIKit

enum JITMethod: String, CaseIterable {
    case waitForDebugger = "Wait for Debugger"
    case stikDebug = "StikDebug"
}

final class JITCoordinator {
    static let shared = JITCoordinator()
    private init() {}

    private weak var presentationController: UIViewController?
    private var onJITReady: (() -> Void)?
    private var waitingForStikDebugReturn = false
    private var waitingForLocalDevVPN = false
    private var readinessChecksRemaining = 0
    private var readinessCheckScheduled = false

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

    var isJITReady: Bool {
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if #available(iOS 17.4, *) {
            return iSteamJITIsReady()
        }
        #endif
        return false
    }

    func requestJIT(from controller: UIViewController?, onReady: (() -> Void)? = nil) {
        presentationController = controller
        onJITReady = onReady
        guard isStikDebugAvailable else {
            failRequest("StikDebug JIT requires iOS 17.4 or later on a physical iOS device.", title: "JIT unavailable")
            return
        }
        guard hasGetTaskAllow else {
            failRequest("This installation does not have the get-task-allow entitlement. Reinstall Akatsubaki Emu with a signing method that preserves this entitlement, then try again.", title: "JIT signing required")
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
        case .stikDebug:
            enableLocalDevVPN()
        }
    }

    @discardableResult
    func handleCallback(_ url: URL) -> Bool {
        guard url.scheme == Bundle.main.bundleIdentifier, waitingForLocalDevVPN else { return false }
        waitingForLocalDevVPN = false
        openStikDebug()
        return true
    }

    func applicationDidBecomeActive() {
        guard waitingForStikDebugReturn else { return }
        readinessChecksRemaining = max(readinessChecksRemaining, 30)
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

        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            guard let self else { return }
            guard opened else {
                self.failRequest("StikDebug could not be opened. Install StikDebug, import this device's pairing file into it, and try again.", title: "StikDebug unavailable")
                return
            }
            self.waitingForStikDebugReturn = true
            self.readinessChecksRemaining = 30
        }
    }

    private func checkReadiness() {
        guard waitingForStikDebugReturn, !readinessCheckScheduled else { return }
        if isJITReady {
            completeJITRequest()
            return
        }
        guard readinessChecksRemaining > 0 else {
            failRequest("JIT was not confirmed. Check that LocalDevVPN has started, StikDebug has a valid pairing file, Developer Mode is enabled, and this app was signed with get-task-allow. If using LiveContainer, enable Use LiveContainer's Bundle ID. No emulation workload was started.", title: "JIT not confirmed")
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
        if let completion {
            completion()
        } else {
            show("JIT is enabled for this process. You can now launch your emulation session.", title: "JIT ready")
        }
    }

    private func failRequest(_ message: String, title: String) {
        waitingForStikDebugReturn = false
        waitingForLocalDevVPN = false
        readinessChecksRemaining = 0
        readinessCheckScheduled = false
        onJITReady = nil
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
