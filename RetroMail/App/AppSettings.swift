import SwiftUI
import UIKit

// MARK: - 外观与语言

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return tr("跟随系统", "System")
        case .light: return tr("日间", "Light")
        case .dark: return tr("夜间", "Dark")
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case zh, en
    var id: String { rawValue }
    var label: String { self == .zh ? "中文" : "English" }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let languageKey = "app.language"
    private static let appearanceKey = "app.appearance"
    private static let threadedKey = "app.threaded"
    private static let hideQuotesKey = "app.hideQuotes"

    @Published var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey) }
    }

    /// 邮件列表按会话分组
    @Published var threaded: Bool {
        didSet { UserDefaults.standard.set(threaded, forKey: Self.threadedKey) }
    }

    /// 会话中默认折叠引用的历史内容
    @Published var hideQuotes: Bool {
        didSet { UserDefaults.standard.set(hideQuotes, forKey: Self.hideQuotesKey) }
    }

    private init() {
        let d = UserDefaults.standard
        appearance = Appearance(rawValue: d.string(forKey: Self.appearanceKey) ?? "") ?? .system
        if let raw = d.string(forKey: Self.languageKey), let l = AppLanguage(rawValue: raw) {
            language = l
        } else {
            let preferred = Locale.preferredLanguages.first ?? "zh"
            let l: AppLanguage = preferred.hasPrefix("zh") ? .zh : .en
            language = l
            d.set(l.rawValue, forKey: Self.languageKey)
        }
        threaded = d.object(forKey: Self.threadedKey) as? Bool ?? true
        hideQuotes = d.object(forKey: Self.hideQuotesKey) as? Bool ?? true
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var isEnglish: Bool { language == .en }
}

/// 界面文字：中文 / English。任何线程都可调用。
func tr(_ zh: String, _ en: String) -> String {
    UserDefaults.standard.string(forKey: AppSettings.languageKey) == "en" ? en : zh
}

// MARK: - 颜色（随日/夜间自动切换）

extension Color {
    /// 墨色：日间黑、夜间近白
    static let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.92, alpha: 1) : .black })
    /// 纸色：日间白、夜间近黑
    static let paper = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1) : .white })
    /// 浅灰：选中、按钮渐变底部
    static let shade = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.24, alpha: 1) : UIColor(white: 0.84, alpha: 1) })
    /// 更浅的灰：按钮渐变
    static let mist = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.14, alpha: 1) : UIColor(white: 0.94, alpha: 1) })
}

extension UIColor {
    static let retroInk = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.92, alpha: 1) : .black }
    static let retroPaper = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.07, alpha: 1) : .white }
}
