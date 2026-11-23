import UIKit

final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        Downloads.shared.restoreSession()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if identifier == "uk.hkot.hkotuner.downloads" {
            Downloads.shared.onBackgroundEvents(completionHandler)
        } else { completionHandler() }
    }
}
