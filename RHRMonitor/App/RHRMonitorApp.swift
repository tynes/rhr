import SwiftUI
import UIKit

/// The app delegate owns the long-lived model so it exists from the moment iOS launches the
/// process — including background relaunches for Bluetooth state restoration, where no UI is
/// created. Nothing that collects or stores data lives in a SwiftUI view.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()
    let keepAwake = KeepAwakeController()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        model.prepareForTermination()
        keepAwake.releaseAll()
    }
}

@main
struct RHRMonitorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appDelegate.model)
                .environment(appDelegate.keepAwake)
                .tint(.red)
        }
    }
}
