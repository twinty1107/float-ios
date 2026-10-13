import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        // 与站点主题色 #f8f7f2 保持一致，避免页面未铺满时露出黑边
        window.backgroundColor = UIColor(red: 0xF8 / 255.0, green: 0xF7 / 255.0, blue: 0xF2 / 255.0, alpha: 1)
        window.rootViewController = WebAppViewController()
        // 不强制 Light/Dark：跟随系统，站点自身用 CSS 适配
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
