import SwiftUI
import UIKit
import UserNotifications

/// 通知：前台也显示横幅；处理通知上的按钮；点通知打开对应邮件。
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MailPrefs.registerDefaults()
        UNUserNotificationCenter.current().delegate = self
        MailNotifier.registerCategories()
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        Task {
            if let fu = info["followUp"] as? String {
                await MainActor.run {
                    switch action {
                    case "fu-done":
                        FollowUpStore.shared.setDone(fu, true)
                    case "fu-later":
                        if var f = FollowUpStore.shared.item(fu) {
                            f.reminder = Date().addingTimeInterval(3600)
                            FollowUpStore.shared.save(f)
                        }
                    default:
                        MailCenter.shared.openFollowUp = fu
                    }
                }
            } else if ["read", "archive", "trash"].contains(action) {
                await MailNotifier.handle(action: action, userInfo: info)
            } else if let idStr = info["account"] as? String, let id = UUID(uuidString: idStr),
                      let folder = info["folder"] as? String, let uid = info["uid"] as? Int {
                await MainActor.run {
                    MailCenter.shared.openRequest = OpenRequest(account: id, folder: folder, uid: uid)
                }
            }
            completionHandler()
        }
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
                .task {
                    if !AccountStore.shared.accounts.isEmpty, BackgroundRefresh.enabled {
                        _ = await MailNotifier.requestPermission()
                    }
                    await CacheArchive.autoRunIfNeeded()
                }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                MailCenter.shared.startLive()
            case .background:
                MailCenter.shared.stopLive()
                BackgroundRefresh.schedule()
            default:
                break
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
