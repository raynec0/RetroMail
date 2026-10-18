import SwiftUI
import UIKit
import UserNotifications

/// 应用在前台时也显示提醒（跟进事项到时间了）。
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

@main
struct RetroMailApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            DesktopView()
                .id(settings.language)
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
                .tint(Color.ink)
                .task { await CacheArchive.autoRunIfNeeded() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                BackgroundRefresh.schedule()
            }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.taskID)) {
            await BackgroundRefresh.run()
        }
    }
}

// 自定义标题栏隐藏了系统导航栏，这里恢复“从左边缘右滑返回”的手势。
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
