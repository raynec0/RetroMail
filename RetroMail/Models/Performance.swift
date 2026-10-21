import Foundation
import UIKit
import WebKit

/// 网页视图预热：所有邮件正文共用一个 WebKit 进程池，并在启动时先建好一个，
/// 第一次打开邮件就不用再等 WebKit 进程启动（约 0.3 秒）。
@MainActor
enum WebWarmup {
    static let pool = WKProcessPool()
    private static var warm: WKWebView?

    static func start() {
        guard warm == nil else { return }
        let cfg = WKWebViewConfiguration()
        cfg.processPool = pool
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 10, height: 10), configuration: cfg)
        wv.loadHTMLString("<html><body></body></html>", baseURL: nil)
        warm = wv
    }
}

/// 解析好的邮件放在内存里（像 Gmail 一样，返回再打开是瞬间的）。内存紧张时系统会自动清掉。
final class DisplayCache {
    static let shared = DisplayCache()
    private let cache = NSCache<NSString, MessageDisplay>()

    private init() {
        cache.countLimit = 120
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
    }

    private func key(_ account: UUID, _ folder: String, _ uid: Int) -> NSString {
        "\(account.uuidString)|\(folder)|\(uid)" as NSString
    }

    func get(_ account: UUID, _ folder: String, _ uid: Int) -> MessageDisplay? {
        cache.object(forKey: key(account, folder, uid))
    }

    func set(_ d: MessageDisplay, _ account: UUID, _ folder: String, _ uid: Int) {
        cache.setObject(d, forKey: key(account, folder, uid))
    }
}

/// 后台预先下载最近邮件的正文（只在 Wi-Fi 或充电时），打开时直接从本机读取。
@MainActor
enum BodyPrefetcher {
    private static var running: Set<String> = []

    static func prefetch(_ list: [MessageSummary], account: MailAccount, folder: String, limit: Int = 25) {
        guard MailPrefs.canPrefetch else { return }
        let key = account.id.uuidString + "|" + folder
        guard !running.contains(key) else { return }
        running.insert(key)
        let candidates = Array(list.filter { $0.uid > 0 && $0.size < 1_500_000 }.prefix(limit))
        let accountId = account.id
        let client = MailCenter.shared.client(for: account, .background)
        Task {
            defer { running.remove(key) }
            let missing = await Task.detached(priority: .utility) { () -> [Int] in
                candidates.filter { !DiskCache.hasRaw(account: accountId, folder: folder, uid: $0.uid) }.map(\.uid)
            }.value
            for uid in missing {
                if !MailPrefs.canPrefetch || UIApplication.shared.applicationState != .active { return }
                guard let raw = try? await client.perform(timeout: 60, { try await $0.fetchRaw(folder, uid: uid) }) else { continue }
                DiskCache.io.async { DiskCache.saveRaw(raw, account: accountId, folder: folder, uid: uid) }
            }
        }
    }
}
