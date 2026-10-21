import Foundation
import SwiftUI
import UIKit
import LocalAuthentication

// MARK: - 常用联系人（写信时自动补全）

@MainActor
final class ContactsStore: ObservableObject {
    static let shared = ContactsStore()

    struct Entry: Codable {
        var name: String
        var email: String
        var score: Double
        var last: Date
    }

    private var entries: [String: Entry] = [:]
    private var dirty = false

    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("contacts.json")
    }

    private init() {
        if let d = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Entry].self, from: d) {
            entries = Dictionary(list.map { ($0.email, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// 记住地址。weight：自己发过信的人权重高，收到的信权重低。
    func learn(_ addrs: [MailAddress], weight: Double, at date: Date = Date()) {
        for a in addrs {
            let key = a.email.lowercased()
            guard key.contains("@"), !key.hasPrefix("no-reply"), !key.hasPrefix("noreply"), !key.contains("mailer-daemon") else { continue }
            var e = entries[key] ?? Entry(name: "", email: key, score: 0, last: .distantPast)
            if !a.name.isEmpty { e.name = a.name }
            e.score += weight
            if date > e.last { e.last = date }
            entries[key] = e
        }
        scheduleSave()
    }

    func learn(from messages: [MessageSummary], myEmail: String) {
        var froms: [MailAddress] = []
        for m in messages.prefix(200) {
            if let f = m.from, f.email.caseInsensitiveCompare(myEmail) != .orderedSame { froms.append(f) }
        }
        learn(froms, weight: 0.2)
    }

    private func scheduleSave() {
        guard !dirty else { return }
        dirty = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.dirty = false
            let list = Array(self.entries.values)
            let target = self.url
            DiskCache.io.async {
                if let d = try? JSONEncoder().encode(list) { try? d.write(to: target, options: .atomic) }
            }
        }
    }

    /// 按输入的前几个字母找联系人（姓名或地址），最近、常用的排前面。
    func suggest(_ q: String, excluding: Set<String> = [], limit: Int = 5) -> [Entry] {
        let s = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return [] }
        let now = Date()
        return entries.values
            .filter { !excluding.contains($0.email) && ($0.email.hasPrefix(s) || $0.email.contains(s) || $0.name.lowercased().contains(s)) }
            .sorted { a, b in
                func rank(_ e: Entry) -> Double {
                    let days = max(1, now.timeIntervalSince(e.last) / 86400)
                    let prefix = e.email.hasPrefix(s) || e.name.lowercased().hasPrefix(s) ? 5.0 : 0
                    return e.score / log2(days + 1) + prefix
                }
                return rank(a) > rank(b)
            }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - 撤销发送 / 发送失败自动存草稿

enum SendPrefs {
    static let undoKey = "mail.undoSendSeconds"
    static var undoSeconds: Int {
        UserDefaults.standard.object(forKey: undoKey) as? Int ?? 5
    }
}

extension MailCenter {
    /// 像 Gmail 一样：点“发送”后马上关闭写信页，底部显示“正在发送 · 撤销”，几秒后才真正发出。
    /// 撤销或发送失败时，邮件会存进草稿箱，内容不会丢。
    func sendWithUndo(_ mail: OutgoingMail, account a: MailAccount,
                      answered: (folder: String, uid: Int)?, removeDraft: (folder: String, uid: Int)?) {
        ContactsStore.shared.learn(mail.to + mail.cc + mail.bcc, weight: 3)
        let delay = SendPrefs.undoSeconds
        let state = SendState()
        let task = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
            if state.cancelled { return }
            state.started = true
            do {
                try await self.send(mail, account: a, answered: answered, removeDraft: removeDraft)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                self.showToast(MailToast(text: tr("已发送", "Sent"), undo: nil))
                if let sent = self.folder(a, role: .sent), let live = MessageListModel.liveModel(account: a.id, folder: sent.path) {
                    await live.refresh()
                }
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                _ = try? await self.saveDraft(mail, account: a, replacing: nil)
                self.showToast(MailToast(text: tr("发送失败，已存到草稿箱：", "Couldn't send; saved to Drafts: ") + error.localizedDescription, undo: nil))
            }
        }
        if delay > 0 {
            showToast(MailToast(text: tr("正在发送…", "Sending…"), undo: {
                guard !state.started else { return }
                state.cancelled = true
                task.cancel()
                Task { @MainActor in
                    _ = try? await MailCenter.shared.saveDraft(mail, account: a, replacing: removeDraft)
                    MailCenter.shared.showToast(MailToast(text: tr("已撤销发送，邮件存在草稿箱里", "Send undone; saved to Drafts"), undo: nil))
                }
            }), duration: Double(delay))
        } else {
            showToast(MailToast(text: tr("正在发送…", "Sending…"), undo: nil))
        }
    }
}

final class SendState {
    var cancelled = false
    var started = false
}

// MARK: - 稍后处理（Snooze）

/// 把邮件“暂时收起来”：从列表里隐藏，到时间后重新出现并提醒（借用跟进事项的提醒）。
@MainActor
enum Snooze {
    private static let key = "mail.snoozed"

    /// 账户|文件夹|UID → 重新出现的时间
    static var all: [String: Date] {
        get { (UserDefaults.standard.dictionary(forKey: key) as? [String: Date]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func k(_ a: UUID, _ folder: String, _ uid: Int) -> String { "\(a.uuidString)|\(folder)|\(uid)" }

    static func hidden(account: UUID, folder: String) -> Set<Int> {
        let now = Date()
        var out = Set<Int>()
        var changed = false
        var dict = all
        for (key, until) in dict {
            if until <= now { dict[key] = nil; changed = true; continue }
            let parts = key.split(separator: "|")
            if parts.count == 3, parts[0] == account.uuidString, parts[1] == folder, let u = Int(parts[2]) { out.insert(u) }
        }
        if changed { all = dict }
        return out
    }

    static func snooze(_ m: MessageSummary, account: MailAccount, folder: String, until: Date) {
        var dict = all
        dict[k(account.id, folder, m.uid)] = until
        all = dict
        // 到时间提醒
        let id = FollowUp.makeId(account: account.id, folder: folder, summary: m)
        var f = FollowUpStore.shared.item(id) ?? FollowUp(id: id, accountId: account.id, folder: folder, summary: m)
        f.flagged = f.flagged && FollowUpStore.shared.item(id) != nil
        f.reminder = until
        FollowUpStore.shared.save(f)
        if let live = MessageListModel.liveModel(account: account.id, folder: folder) {
            live.removeLocally([m.uid])
        }
    }

    static var options: [(String, Date)] {
        let cal = Calendar.current
        let now = Date()
        func at(_ d: Date, _ h: Int) -> Date { cal.date(bySettingHour: h, minute: 0, second: 0, of: d) ?? d }
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
        var nextMon = tomorrow
        while cal.component(.weekday, from: nextMon) != 2 { nextMon = cal.date(byAdding: .day, value: 1, to: nextMon)! }
        var weekend = now
        while cal.component(.weekday, from: weekend) != 7 { weekend = cal.date(byAdding: .day, value: 1, to: weekend)! }
        var list: [(String, Date)] = [(tr("1 小时后", "In 1 hour"), now.addingTimeInterval(3600))]
        let tonight = at(now, 19)
        if tonight > now.addingTimeInterval(1800) { list.append((tr("今晚 19:00", "This evening"), tonight)) }
        list.append((tr("明天早上 9:00", "Tomorrow morning"), at(tomorrow, 9)))
        if cal.component(.weekday, from: now) < 6 { list.append((tr("这个周末", "This weekend"), at(weekend, 10))) }
        list.append((tr("下周一 9:00", "Next Monday"), at(nextMon, 9)))
        return list
    }
}

// MARK: - 面容 ID / 密码锁

@MainActor
final class AppLock: ObservableObject {
    static let shared = AppLock()
    static let key = "app.lockEnabled"

    @Published private(set) var locked = false
    private var lastBackground: Date?

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.key) }

    private init() {
        locked = enabled
    }

    func didEnterBackground() {
        lastBackground = Date()
    }

    func willEnterForeground() {
        // 离开超过 1 分钟才重新上锁
        if enabled, let t = lastBackground, Date().timeIntervalSince(t) > 60 { locked = true }
        lastBackground = nil
    }

    func unlock() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            locked = false
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: tr("解锁 RetroMail", "Unlock RetroMail")) { ok, _ in
            Task { @MainActor in if ok { AppLock.shared.locked = false } }
        }
    }
}

struct LockScreen: View {
    @ObservedObject private var lock = AppLock.shared

    var body: some View {
        ZStack {
            PinstripeBackground().ignoresSafeArea()
            VStack(spacing: 18) {
                Image("mbx-folder-locked").resizable().interpolation(.high).frame(width: 96, height: 96)
                Text("RetroMail").font(RT.font(26, .bold)).foregroundColor(IOS3.groupHeader)
                    .shadow(color: IOS3.groupHeaderShadow, radius: 0, x: 0, y: 1)
                Button(tr("解锁", "Unlock")) { lock.unlock() }
                    .buttonStyle(RetroButtonStyle(isDefault: true))
            }
        }
        .onAppear { lock.unlock() }
    }
}

// MARK: - 打印 / 导出 PDF

enum MailPrinter {
    @MainActor
    static func print(html: String, title: String) {
        let pc = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = title
        pc.printInfo = info
        pc.printFormatter = UIMarkupTextPrintFormatter(markupText: html)
        pc.present(animated: true)
    }
}
