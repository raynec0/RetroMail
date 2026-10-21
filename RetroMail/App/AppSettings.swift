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
    private static let mailboxIconsKey = "app.mailboxIcons"
    private static let folderIconsKey = "app.folderIcons"
    static let textScaleKey = "app.textScale"

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

    /// 首页邮箱按钮是否显示图标
    @Published var mailboxIcons: Bool {
        didSet { UserDefaults.standard.set(mailboxIcons, forKey: Self.mailboxIconsKey) }
    }

    /// 字号缩放：0.9 / 1 / 1.15 / 1.3
    @Published var textScale: Double {
        didSet {
            UserDefaults.standard.set(textScale, forKey: Self.textScaleKey)
            RT.scale = CGFloat(textScale)
        }
    }

    /// 用户为文件夹挑选的图标：键为“账户ID|文件夹路径”，值为图标资源名
    @Published var folderIcons: [String: String] {
        didSet { UserDefaults.standard.set(folderIcons, forKey: Self.folderIconsKey) }
    }

    func folderIcon(account: UUID, path: String) -> String? {
        folderIcons[account.uuidString + "|" + path]
    }

    func setFolderIcon(_ name: String?, account: UUID, path: String) {
        folderIcons[account.uuidString + "|" + path] = name
    }

    func moveFolderIcon(account: UUID, from old: String, to new: String) {
        let prefix = account.uuidString + "|"
        var next = folderIcons
        for (k, v) in folderIcons where k.hasPrefix(prefix) {
            let p = String(k.dropFirst(prefix.count))
            if p == old || p.hasPrefix(old) && p.count > old.count {
                next[k] = nil
                next[prefix + new + p.dropFirst(old.count)] = v
            }
        }
        folderIcons = next
    }

    private init() {
        let d = UserDefaults.standard
        folderIcons = d.dictionary(forKey: Self.folderIconsKey) as? [String: String] ?? [:]
        let ts = d.double(forKey: Self.textScaleKey)
        textScale = ts > 0 ? ts : 1
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
        mailboxIcons = d.object(forKey: Self.mailboxIconsKey) as? Bool ?? true
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
