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

    var isJITProtocolSupported: Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            return iSteamJITIsSupported()
        }
        #endif
        // The breakpoint protocol is specific to supported iOS releases;
        // arm64 alone does not make it available on visionOS or older iOS.
        return false
    }

    func requestJIT(from controller: UIViewController?) {
        guard isJITProtocolSupported else {
            show("This device or build does not support the StikDebug JIT breakpoint protocol.", title: "JIT unavailable", on: controller)
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
        c.queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleID),
            URLQueryItem(name: "pid", value: String(getpid())),
            URLQueryItem(name: "script-name", value: "universal.js")
        ]
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
