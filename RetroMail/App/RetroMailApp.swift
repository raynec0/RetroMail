import SwiftUI
import UIKit

@main
struct RetroMailApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            DesktopView()
                .id(settings.language)
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
                .tint(Color.ink)
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
