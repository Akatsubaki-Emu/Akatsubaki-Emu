import Foundation
import UIKit

enum JITMethod: String, CaseIterable {
    case waitForDebugger = "Wait for Debugger"
    case stikDebug = "StikDebug"
}

final class JITCoordinator {
    static let shared = JITCoordinator()
    private init() {}

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

    // The entitlement cannot be queried with SecTask on the public iOS SDK.
    // Keep this conservative; signing/JIT helpers are responsible for granting it.
    var hasGetTaskAllow: Bool { false }

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

    func requestJIT(from controller: UIViewController?) {
        guard isStikDebugAvailable else {
            show("StikDebug JIT requires iOS 17.4 or later on a physical iOS device.", title: "JIT unavailable", on: controller)
            return
        }

        switch selectedMethod {
        case .waitForDebugger:
            show("Attach StikDebug or another compatible JIT debugger to this process. The signer must grant the required debugging entitlement.", title: "Waiting for debugger", on: controller)
        case .stikDebug:
            openStikDebug(on: controller)
        }
    }

    private func openStikDebug(on controller: UIViewController?) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        var c = URLComponents()
        c.scheme = "stikdebug"
        c.host = "enable-jit"
        var queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleID),
            URLQueryItem(name: "pid", value: String(getpid()))
        ]
        // The iOS 26+ breakpoint protocol uses the universal script. Older
        // supported iOS releases enable JIT through debugger attachment alone.
        if #available(iOS 26.0, *), isJITProtocolSupported {
            queryItems.append(URLQueryItem(name: "script-name", value: "universal.js"))
        }
        c.queryItems = queryItems
        guard let url = c.url else { return }
        UIApplication.shared.open(url, options: [:]) { [weak self, weak controller] opened in
            guard !opened else { return }
            self?.show("StikDebug could not be opened. Check that it is installed and its URL scheme is available.", title: "JIT helper unavailable", on: controller)
        }
    }

    private func show(_ message: String, title: String, on controller: UIViewController?) {
        guard let controller else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        controller.present(alert, animated: true)
    }
}
