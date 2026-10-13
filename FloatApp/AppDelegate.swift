import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = .black
        window.rootViewController = WebAppViewController()
        if #available(iOS 13.0, *) {
            window.overrideUserInterfaceStyle = .light
        }
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
