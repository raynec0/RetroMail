import Foundation
import BackgroundTasks
import UserNotifications

/// 全局邮件服务：管理每个账户的 IMAP 连接、文件夹和未读数。
@MainActor
final class MailCenter: ObservableObject {
    static let shared = MailCenter()

    @Published var folders: [UUID: [MailFolder]] = [:]
    @Published var unread: [String: Int] = [:]
    @Published var folderErrors: [UUID: String] = [:]
    @Published var loadingAccounts: Set<UUID> = []

    private var clients: [UUID: IMAPClient] = [:]

    private init() {}

    func client(for a: MailAccount) -> IMAPClient {
        if let c = clients[a.id] { return c }
        let c = IMAPClient(config: a.imapConfig())
        clients[a.id] = c
        return c
    }

    /// 账户设置改变后丢弃旧连接。
    func reset(_ id: UUID) {
        if let old = clients.removeValue(forKey: id) {
            Task { await old.shutdown() }
        }
        folders[id] = nil
        folderErrors[id] = nil
    }

    func unreadKey(_ id: UUID, _ path: String) -> String { id.uuidString + "|" + path }

    func folder(_ a: MailAccount, role: FolderRole) -> MailFolder? {
        folders[a.id]?.first { $0.role == role && $0.selectable }
    }

    func loadAll() async {
        for a in AccountStore.shared.accounts {
            if folders[a.id] == nil, let cached = DiskCache.loadFolders(account: a.id) {
                folders[a.id] = cached
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for a in AccountStore.shared.accounts {
                group.addTask { await self.loadFolders(a) }
            }
        }
    }

    func loadFolders(_ a: MailAccount) async {
        loadingAccounts.insert(a.id)
        defer { loadingAccounts.remove(a.id) }
        do {
            let list = try await client(for: a).perform { try await $0.listFolders() }
            let sorted = MailFolder.sorted(list)
            folders[a.id] = sorted
            folderErrors[a.id] = nil
            DiskCache.saveFolders(sorted, account: a.id)
            await refreshUnread(a)
        } catch {
            folderErrors[a.id] = error.localizedDescription
        }
    }

    func refreshUnread(_ a: MailAccount) async {
        guard let list = folders[a.id] else { return }
        let c = client(for: a)
        for f in list where f.selectable && ![.sent, .drafts, .trash].contains(f.role) {
            let p = f.path
            if let st = try? await c.perform({ try await $0.status(p) }) {
                unread[unreadKey(a.id, p)] = st.unseen
                if f.role == .inbox, st.uidNext > 0 {
                    BackgroundRefresh.noteSeen(account: a.id, nextUID: st.uidNext)
                }
            }
        }
    }

    func adjustUnread(_ a: MailAccount, _ path: String, by delta: Int) {
        let k = unreadKey(a.id, path)
        unread[k] = max(0, (unread[k] ?? 0) + delta)
    }

    // MARK: - 会话：跨文件夹查找相关邮件

    /// 在“已发送”“收件箱”等文件夹里查找属于同一会话的邮件（Outlook 会话视图的做法）。
    func relatedMessages(_ a: MailAccount, conversation: Conversation, currentFolder: String) async -> [(folder: String, summary: MessageSummary)] {
        if folders[a.id] == nil { await loadFolders(a) }
        let core = Threading.core(conversation.latest.subject)
        guard !core.isEmpty else { return [] }
        var targets: [String] = []
        for role in [FolderRole.inbox, .sent] {
            if let f = folder(a, role: role), f.path != currentFolder { targets.append(f.path) }
        }
        let c = client(for: a)
        var out: [(folder: String, summary: MessageSummary)] = []
        for path in targets {
            guard let found = try? await c.perform({ try await $0.searchSubject(path, subject: core, limit: 30) }) else { continue }
            for m in found where conversation.messages.contains(where: { Threading.related($0, m) }) {
                out.append((path, m))
            }
        }
        return out
    }

    // MARK: - 发信 / 草稿

    func send(_ mail: OutgoingMail, account a: MailAccount,
              answered: (folder: String, uid: Int)?, removeDraft: (folder: String, uid: Int)?) async throws {
        if folders[a.id] == nil { await loadFolders(a) }
        let wire = await Task.detached { MIMEBuilder.build(mail, includeBcc: false) }.value
        let smtp = SMTPClient(config: a.smtpConfig())
        try await smtp.send(wire, from: a.email, to: mail.allRecipients)

        let c = client(for: a)
        if a.saveToSent, let sent = folder(a, role: .sent) {
            let copy = await Task.detached { MIMEBuilder.build(mail, includeBcc: true) }.value
            let path = sent.path
            _ = try? await c.perform { try await $0.append(path, message: copy, flags: "\\Seen") }
        }
        if let ref = answered {
            _ = try? await c.perform { try await $0.store(ref.folder, uids: [ref.uid], flag: "\\Answered", add: true) }
        }
        if let ref = removeDraft {
            _ = try? await c.perform { try await $0.delete(ref.folder, uids: [ref.uid], trash: nil) }
        }
    }

    func saveDraft(_ mail: OutgoingMail, account a: MailAccount, replacing: (folder: String, uid: Int)?) async throws {
        if folders[a.id] == nil { await loadFolders(a) }
        guard let drafts = folder(a, role: .drafts) else {
            throw MailError.protocolError(tr("没有找到“草稿箱”文件夹。", "No Drafts folder was found."))
        }
        let data = await Task.detached { MIMEBuilder.build(mail, includeBcc: true) }.value
        let path = drafts.path
        let c = client(for: a)
        try await c.perform { try await $0.append(path, message: data, flags: "\\Draft \\Seen") }
        if let ref = replacing {
            _ = try? await c.perform { try await $0.delete(ref.folder, uids: [ref.uid], trash: nil) }
        }
    }
}

// MARK: - 后台检查新邮件 + 本地通知

enum BackgroundRefresh {
    static let taskID = "com.raynec.retromail.refresh"
    static let enabledKey = "notifyNewMail"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static func schedule() {
        guard enabled else { return }
        let req = BGAppRefreshTaskRequest(identifier: taskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    private static func key(_ id: UUID) -> String { "nextUID.\(id.uuidString)" }

    /// 前台已经看到的邮件不再通知。
    static func noteSeen(account: UUID, nextUID: Int) {
        let k = key(account)
        if nextUID > UserDefaults.standard.integer(forKey: k) {
            UserDefaults.standard.set(nextUID, forKey: k)
        }
    }

    static func run() async {
        schedule()
        guard enabled else { return }
        let accounts = AccountStore.loadFromDisk()
        for a in accounts {
            let client = IMAPClient(config: a.imapConfig())
            do {
                let last = UserDefaults.standard.integer(forKey: key(a.id))
                let st = try await client.perform { try await $0.status("INBOX") }
                if last > 0, st.uidNext > last {
                    let fresh = try await client.perform { try await $0.fetchSince("INBOX", uid: last) }
                    await notify(a, fresh.filter { !$0.seen }, multiAccount: accounts.count > 1)
                }
                if st.uidNext > 0 { UserDefaults.standard.set(st.uidNext, forKey: key(a.id)) }
            } catch {
                // 后台失败静默忽略，下次再试。
            }
            await client.shutdown()
        }
    }

    private static func notify(_ a: MailAccount, _ msgs: [MessageSummary], multiAccount: Bool) async {
        guard !msgs.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        for m in msgs.prefix(5) {
            let c = UNMutableNotificationContent()
            c.title = m.from?.display ?? a.email
            if multiAccount { c.subtitle = a.email }
            c.body = m.subject.isEmpty ? tr("（无主题）", "(No subject)") : m.subject
            c.sound = .default
            c.threadIdentifier = a.id.uuidString
            let req = UNNotificationRequest(identifier: "\(a.id.uuidString)-\(m.uid)", content: c, trigger: nil)
            try? await center.add(req)
        }
        if msgs.count > 5 {
            let c = UNMutableNotificationContent()
            c.title = "RetroMail"
            c.body = tr("\(a.email) 还有 \(msgs.count - 5) 封新邮件", "\(msgs.count - 5) more new messages for \(a.email)")
            c.threadIdentifier = a.id.uuidString
            try? await center.add(UNNotificationRequest(identifier: "\(a.id.uuidString)-more", content: c, trigger: nil))
        }
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}
