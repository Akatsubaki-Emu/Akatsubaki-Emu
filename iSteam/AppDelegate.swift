import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CrashLogger.shared.install()
        StikPairingCoordinator.shared.registerBackgroundTask()
        // Keep every UIKit toggle visually consistent with the app's native iOS controls.
        UISwitch.appearance().onTintColor = .systemGreen
        UISwitch.appearance().tintColor = .systemGray4
        UISwitch.appearance().thumbTintColor = .white
        #if os(visionOS)
        let window = UIWindow()
        #else
        let window = UIWindow(frame: UIScreen.main.bounds)
        #endif
        let navigation = UINavigationController(rootViewController: LibraryViewController())
        navigation.navigationBar.prefersLargeTitles = true
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        JITCoordinator.shared.handleCallback(url)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        JITCoordinator.shared.applicationDidBecomeActive()
        StikPairingCoordinator.shared.applicationDidBecomeActive()
    }
}
