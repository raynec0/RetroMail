import Foundation
import SwiftUI
import UIKit
import UserNotifications
import Network
import AVFoundation

// MARK: - 设置

enum MailPrefs {
    static let autoRefreshKey = "mail.autoRefreshMinutes"
    static let previewKey = "mail.notifyPreview"
    static let idleKey = "mail.useIdle"
    static let badgeKey = "mail.badge"
    static let keepAliveKey = "mail.backgroundKeepAlive"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            BackgroundRefresh.enabledKey: true,
            autoRefreshKey: 2,
            previewKey: true,
            idleKey: true,
            badgeKey: true,
            keepAliveKey: true,
        ])
    }

    static var autoRefreshMinutes: Int { UserDefaults.standard.integer(forKey: autoRefreshKey) }
    static var showPreview: Bool { UserDefaults.standard.bool(forKey: previewKey) }
    static var useIdle: Bool { UserDefaults.standard.bool(forKey: idleKey) }
    static var badge: Bool { UserDefaults.standard.bool(forKey: badgeKey) }
    static var keepAlive: Bool { UserDefaults.standard.bool(forKey: keepAliveKey) }
}

// MARK: - 后台保持在线

/// 自签应用用不了苹果推送服务。为了在后台也能“秒到”，可以让应用在后台保持运行（播放无声音频，和音乐同时存在、不会打断），
/// 这样 IDLE 连接一直在线，新邮件一到就推送通知。代价是会多耗一些电。
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observers: [NSObjectProtocol] = []

    var isRunning: Bool { engine?.isRunning ?? false }

    func start() {
        guard engine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let e = AVAudioEngine()
            let p = AVAudioPlayerNode()
            e.attach(p)
            let format = e.mainMixerNode.outputFormat(forBus: 0)
            e.connect(p, to: e.mainMixerNode, format: format)
            e.mainMixerNode.outputVolume = 0
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else { return }
            buffer.frameLength = buffer.frameCapacity   // 全是 0：无声
            try e.start()
            p.scheduleBuffer(buffer, at: nil, options: .loops)
            p.play()
            engine = e
            player = p
            // 被电话等打断后自动恢复
            observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { n in
                guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                Task { @MainActor in
                    BackgroundKeeper.shared.stop()
                    BackgroundKeeper.shared.start()
                }
            })
        } catch {
            stop()
        }
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

final class BackgroundTaskBox {
    var id: UIBackgroundTaskIdentifier = .invalid
}

// MARK: - 网络变化

@MainActor
final class NetworkWatcher {
    static let shared = NetworkWatcher()
    private let monitor = NWPathMonitor()
    private(set) var online = true
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            let ok = path.status == .satisfied
            Task { @MainActor in
                let was = NetworkWatcher.shared.online
                NetworkWatcher.shared.online = ok
                // 网络恢复（或从 Wi-Fi 切到蜂窝）：旧连接多半已经失效，马上重连并补发积压的操作
                if ok && !was {
                    MailCenter.shared.networkChanged()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "retromail.net"))
    }
}

// MARK: - 操作提示（“已移到归档 · 撤销”）

struct MailToast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var undo: (() -> Void)?

    static func == (a: MailToast, b: MailToast) -> Bool { a.id == b.id }
}

/// 从通知点进来时要打开的邮件
struct OpenRequest: Equatable {
    let account: UUID
    let folder: String
    let uid: Int
}

// MARK: - 实时收信：IDLE + 定时检查

extension MailCenter {
    /// 回到前台（或后台保持在线时）：立即检查一次，然后用 IDLE 等新邮件，同时按设置的间隔定时检查。
    func startLive() {
        NetworkWatcher.shared.start()
        BackgroundKeeper.shared.stop()
        if !liveTasks.isEmpty && !idleConnections.isEmpty {
            // 已经在线（从后台保持在线状态回来）：只补一次检查
            Task { await checkAll(lists: true, full: true) }
            MailActions.shared.kickAll()
            return
        }
        stopLive()
        MailActions.shared.kickAll()
        liveTasks.append(Task { [weak self] in
            guard let self = self else { return }
            await self.checkAll(lists: true, full: true)
            var tick = 0
            while !Task.isCancelled {
                let minutes = max(1, MailPrefs.autoRefreshMinutes)
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
                if Task.isCancelled { return }
                tick += 1
                if MailPrefs.autoRefreshMinutes > 0 {
                    // 每次只查收件箱和正在看的列表；所有文件夹的未读数每 10 分钟查一次
                    await self.checkAll(lists: true, full: tick * minutes % 10 == 0)
                }
            }
        })
        if MailPrefs.useIdle {
            for a in AccountStore.shared.accounts {
                liveTasks.append(Task { [weak self] in await self?.idleLoop(a) })
            }
        }
    }

    func stopLive() {
        liveTasks.forEach { $0.cancel() }
        liveTasks = []
        for c in idleConnections.values { c.close() }
        idleConnections = [:]
    }

    /// 切到后台：开了“后台保持在线”就继续 IDLE；否则给 30 秒把排队的操作发完再断开。
    func enterBackground() {
        if MailPrefs.keepAlive && MailPrefs.useIdle && !AccountStore.shared.accounts.isEmpty {
            BackgroundKeeper.shared.start()
            if BackgroundKeeper.shared.isRunning {
                if liveTasks.isEmpty { startLiveKeepingAudio() }
                return
            }
        }
        let box = BackgroundTaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "flush") {
            UIApplication.shared.endBackgroundTask(box.id)
            box.id = .invalid
        }
        Task {
            MailActions.shared.kickAll()
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if UIApplication.shared.applicationState == .background && !BackgroundKeeper.shared.isRunning {
                self.stopLive()
            }
            if box.id != .invalid {
                UIApplication.shared.endBackgroundTask(box.id)
                box.id = .invalid
            }
        }
    }

    private func startLiveKeepingAudio() {
        let keep = BackgroundKeeper.shared.isRunning
        startLive()
        if keep { BackgroundKeeper.shared.start() }
    }

    /// 网络恢复：断开所有旧连接重新来过。
    func networkChanged() {
        for a in AccountStore.shared.accounts {
            for lane in Lane.allCases {
                if let c = clients.removeValue(forKey: a.id.uuidString + "|" + lane.rawValue) {
                    Task { await c.shutdown() }
                }
            }
        }
        let keep = BackgroundKeeper.shared.isRunning
        stopLive()
        startLive()
        if keep { BackgroundKeeper.shared.start() }
    }

    /// 检查所有账户的新邮件，更新未读数，并刷新正在显示的列表。
    func checkAll(lists: Bool, full: Bool = false) async {
        await withTaskGroup(of: Void.self) { g in
            for a in AccountStore.shared.accounts {
                g.addTask { @MainActor in
                    await self.checkNewMail(a)
                    if full { await self.refreshUnread(a) }
                }
            }
        }
        lastUpdated = Date()
        if lists {
            for m in MessageListModel.liveModels() {
                await m.refresh()
            }
        }
        updateBadge()
    }

    private func idleLoop(_ a: MailAccount) async {
        var failures = 0
        while !Task.isCancelled {
            let conn = IMAPConnection(config: a.imapConfig())
            idleConnections[a.id] = conn
            do {
                try await conn.connect()
                guard conn.supportsIdle else {
                    conn.close()
                    idleConnections[a.id] = nil
                    return  // 不支持 IDLE：靠定时检查
                }
                failures = 0
                let inbox = folder(a, role: .inbox)?.path ?? "INBOX"
                while !Task.isCancelled {
                    // 大多数服务器 30 分钟断开 IDLE；这里 8 分钟重新进入一次（顺便确认连接还活着）
                    let changed = try await conn.idleOnce(inbox, maxWait: 480)
                    if changed {
                        await checkNewMail(a, on: conn)
                        for m in MessageListModel.liveModels() where m.account.id == a.id && m.folder.path == inbox {
                            await m.refresh()
                        }
                        updateBadge()
                    }
                }
            } catch {
                conn.close()
                if Task.isCancelled { return }
                failures += 1
                // 超时（每 8 分钟一次）属于正常情况，马上重连；连续失败则逐渐放慢；没网时等网络恢复的通知
                let wait = failures <= 1 ? 1 : min(120, 10 * failures)
                try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            }
        }
    }

    /// 收件箱里有没有新邮件；有的话发通知。
    /// conn：IDLE 刚收到通知时直接用那条连接查，不用排队等别的连接。
    func checkNewMail(_ a: MailAccount, on conn: IMAPConnection? = nil) async {
        let inbox = folder(a, role: .inbox)?.path ?? "INBOX"
        let bg = client(for: a, .background)
        func run<T>(_ op: (IMAPConnection) async throws -> T) async throws -> T {
            if let c = conn { return try await op(c) }
            return try await bg.perform(timeout: 30, op)
        }
        guard let st = try? await run({ try await $0.status(inbox) }) else { return }
        let last = BackgroundRefresh.lastUID(a.id)
        if last > 0, st.uidNext > last,
           let fresh = try? await run({ try await $0.fetchSince(inbox, uid: last) }) {
            let unseen = fresh.filter { !$0.seen }
            if !unseen.isEmpty {
                var previews: [Int: Data] = [:]
                if MailPrefs.showPreview {
                    let uids = Array(unseen.map(\.uid).prefix(8))
                    previews = (try? await run({ try await $0.fetchPreviews(inbox, uids: uids, bytes: 1200) })) ?? [:]
                }
                await MailNotifier.post(unseen, account: a, folder: inbox, previews: previews)
            }
        }
        if st.uidNext > 0 { BackgroundRefresh.setLastUID(a.id, st.uidNext) }
        unread[unreadKey(a.id, inbox)] = st.unseen
    }

    func updateBadge() {
        guard MailPrefs.badge else { return }
        var total = 0
        for a in AccountStore.shared.accounts {
            let inbox = folder(a, role: .inbox)?.path ?? "INBOX"
            total += unread[unreadKey(a.id, inbox)] ?? 0
        }
        MailNotifier.setBadge(total)
    }

    // MARK: 移动后立即更新目标文件夹

    func didMove(_ a: MailAccount, from source: String, to dest: MailFolder, messages: [MessageSummary],
                 uidMap: [Int: Int], announce: Bool, deleted: Bool = false) {
        var mapped: [MessageSummary] = []
        for m in messages {
            guard let n = uidMap[m.uid] else { continue }
            var x = m
            x.uid = n
            x.folderPath = nil
            mapped.append(x)
        }
        if !mapped.isEmpty {
            if let live = MessageListModel.liveModel(account: a.id, folder: dest.path) {
                live.insertMoved(mapped)
            }
            var cached = DiskCache.loadList(account: a.id, folder: dest.path)
            let have = Set(cached.map(\.uid))
            cached += mapped.filter { !have.contains($0.uid) }
            cached.sort(by: MessageSummary.newestFirst)
            DiskCache.saveList(Array(cached.prefix(120)), account: a.id, folder: dest.path)
        } else if let live = MessageListModel.liveModel(account: a.id, folder: dest.path) {
            Task { await live.refresh() }
        }
        // 跟进事项跟着邮件走
        for m in messages {
            guard let newUID = uidMap[m.uid] else { continue }
            var x = m
            x.uid = newUID
            x.folderPath = nil
            FollowUpStore.shared.refreshSummary(FollowUp.makeId(account: a.id, folder: source, summary: m), folder: dest.path, summary: x)
        }
        guard announce else { return }
        let n = messages.count
        let text = deleted
            ? tr("已删除 \(n) 封邮件", "Deleted \(n) message\(n == 1 ? "" : "s")")
            : tr("已移到“\(dest.displayName)”", "Moved to \(dest.displayName)")
        var undo: (() -> Void)?
        if !mapped.isEmpty {
            let newUIDs = mapped.map(\.uid)
            undo = { [weak self] in
                Task { @MainActor in
                    guard let self = self else { return }
                    _ = try? await self.client(for: a, .interactive).perform {
                        try await $0.move(dest.path, uids: newUIDs, to: source)
                    }
                    if let live = MessageListModel.liveModel(account: a.id, folder: source) { await live.refresh() }
                    if let live = MessageListModel.liveModel(account: a.id, folder: dest.path) { await live.refresh() }
                    await self.refreshUnread(a, paths: [source, dest.path])
                }
            }
        }
        showToast(MailToast(text: text, undo: undo))
    }

    func showToast(_ t: MailToast) {
        toast = t
        let id = t.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if self?.toast?.id == id { self?.toast = nil }
        }
    }
}

// MARK: - 通知

enum MailNotifier {
    static let mailCategory = "MAIL"
    static let followUpCategory = "FOLLOWUP"

    static func registerCategories() {
        let read = UNNotificationAction(identifier: "read", title: tr("标为已读", "Mark as Read"), options: [])
        let archive = UNNotificationAction(identifier: "archive", title: tr("归档", "Archive"), options: [])
        let trash = UNNotificationAction(identifier: "trash", title: tr("删除", "Delete"), options: [.destructive])
        let reply = UNNotificationAction(identifier: "reply", title: tr("回复", "Reply"), options: [.foreground])
        let mail = UNNotificationCategory(identifier: mailCategory, actions: [read, archive, trash, reply], intentIdentifiers: [],
                                          hiddenPreviewsBodyPlaceholder: tr("新邮件", "New Mail"),
                                          categorySummaryFormat: tr("还有 %u 封邮件", "%u more messages"), options: [])
        let done = UNNotificationAction(identifier: "fu-done", title: tr("完成", "Done"), options: [])
        let later = UNNotificationAction(identifier: "fu-later", title: tr("1 小时后再提醒", "Remind in 1 Hour"), options: [])
        let fu = UNNotificationCategory(identifier: followUpCategory, actions: [done, later], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([mail, fu])
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// 新邮件通知：标题是发件人，副标题是主题，正文是邮件开头几行；同一会话的通知叠在一起。
    static func post(_ msgs: [MessageSummary], account a: MailAccount, folder: String, previews raw: [Int: Data]) async {
        guard BackgroundRefresh.enabled else { return }
        let list = Array(msgs.sorted(by: MessageSummary.newestFirst).prefix(8))
        var previews: [Int: String] = [:]
        for m in list {
            if let d = raw[m.uid] {
                previews[m.uid] = PreviewText.extract(d, contentType: m.contentType, transferEncoding: m.transferEncoding)
            }
        }
        let multi = AccountStore.loadFromDisk().count > 1
        let center = UNUserNotificationCenter.current()
        for m in list {
            let c = UNMutableNotificationContent()
            c.title = m.from?.display ?? a.email
            c.subtitle = m.subject.isEmpty ? tr("（无主题）", "(No Subject)") : m.subject
            var body = MailPrefs.showPreview ? (previews[m.uid] ?? m.preview ?? "") : ""
            if body.count > 180 { body = String(body.prefix(180)) + "…" }
            if body.isEmpty { body = m.hasAttachment ? tr("📎 含附件", "📎 Attachment") : tr("新邮件", "New message") }
            else if m.hasAttachment { body = "📎 " + body }
            if multi { body += "\n— " + (a.name.isEmpty ? a.email : a.name) }
            c.body = body
            c.sound = .default
            c.categoryIdentifier = mailCategory
            c.threadIdentifier = a.id.uuidString + "|" + Threading.core(m.subject)
            c.summaryArgument = m.from?.display ?? ""
            c.userInfo = ["account": a.id.uuidString, "folder": folder, "uid": m.uid]
            c.relevanceScore = 0.5
            if #available(iOS 15.0, *) { c.interruptionLevel = .active }
            let req = UNNotificationRequest(identifier: "mail-\(a.id.uuidString)-\(m.uid)", content: c, trigger: nil)
            try? await center.add(req)
        }
    }

    @MainActor
    static func setBadge(_ n: Int) {
        if #available(iOS 17.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(n)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = n
        }
    }

    /// 通知上的按钮（标为已读 / 归档 / 删除），应用可能在后台被唤起执行。
    static func handle(action: String, userInfo: [AnyHashable: Any]) async {
        guard let idStr = userInfo["account"] as? String, let id = UUID(uuidString: idStr),
              let folder = userInfo["folder"] as? String, let uid = userInfo["uid"] as? Int,
              let a = AccountStore.loadFromDisk().first(where: { $0.id == id }) else { return }
        let folders = DiskCache.loadFolders(account: id) ?? []
        let client = IMAPClient(config: a.imapConfig())
        switch action {
        case "read":
            _ = try? await client.perform { try await $0.store(folder, uids: [uid], flag: "\\Seen", add: true) }
        case "archive":
            if let dest = folders.first(where: { $0.role == .archive && $0.selectable }) {
                _ = try? await client.perform { try await $0.move(folder, uids: [uid], to: dest.path) }
            } else {
                _ = try? await client.perform { try await $0.store(folder, uids: [uid], flag: "\\Seen", add: true) }
            }
        case "trash":
            let trash = folders.first(where: { $0.role == .trash && $0.selectable })?.path
            _ = try? await client.perform { try await $0.delete(folder, uids: [uid], trash: trash) }
        default:
            break
        }
        await client.shutdown()
        await MainActor.run {
            for m in MessageListModel.liveModels() where m.account.id == id && m.folder.path == folder {
                Task { await m.refresh() }
            }
            Task { await MailCenter.shared.refreshUnread(a, paths: [folder]); MailCenter.shared.updateBadge() }
        }
    }
}
