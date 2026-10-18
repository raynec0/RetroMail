import Foundation
import UserNotifications
import EventKit

/// 一封邮件的跟进信息：旗标、提醒、截止日期、备注。
struct FollowUp: Codable, Identifiable, Hashable {
    enum FlagColor: Int, Codable, CaseIterable, Identifiable {
        case red, orange, blue, green
        var id: Int { rawValue }

        var asset: String {
            switch self {
            case .red: return "fu-flag"
            case .orange: return "fu-flag-orange"
            case .blue: return "fu-flag-blue"
            case .green: return "fu-flag-green"
            }
        }

        var label: String {
            switch self {
            case .red: return tr("红色", "Red")
            case .orange: return tr("黄色", "Yellow")
            case .blue: return tr("蓝色", "Blue")
            case .green: return tr("绿色", "Green")
            }
        }
    }

    enum Priority: Int, Codable, CaseIterable, Identifiable {
        case low, normal, high
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .low: return tr("低", "Low")
            case .normal: return tr("普通", "Normal")
            case .high: return tr("高", "High")
            }
        }
    }

    var id: String
    var accountId: UUID
    var folder: String
    var summary: MessageSummary

    var flagged = true
    var flagColor: FlagColor = .red
    var priority: Priority = .normal
    var note = ""
    var deadline: Date?
    var reminder: Date?
    var done = false
    var doneAt: Date?
    var created = Date()
    var updated = Date()
    /// 已添加到 iOS “提醒事项”的条目
    var reminderItemId: String?

    static func makeId(account: UUID, folder: String, summary: MessageSummary) -> String {
        if let mid = summary.messageId, !mid.isEmpty { return account.uuidString + "|" + mid }
        return account.uuidString + "|" + folder + "|" + String(summary.uid)
    }

    var subject: String { summary.subject.isEmpty ? tr("（无主题）", "(No Subject)") : summary.subject }
    var sender: String { summary.from?.display ?? "" }

    var isOverdue: Bool {
        guard !done, let d = deadline else { return false }
        return d < Date()
    }

    /// 排序用：先看截止日期，再看提醒时间，最后看加入时间。
    var sortDate: Date { deadline ?? reminder ?? created.addingTimeInterval(365 * 86400 * 10) }

    var isEmpty: Bool { !flagged && note.isEmpty && deadline == nil && reminder == nil }
}

@MainActor
final class FollowUpStore: ObservableObject {
    static let shared = FollowUpStore()

    @Published private(set) var items: [String: FollowUp] = [:]

    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("followups.json")
    }

    private init() {
        if let d = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([FollowUp].self, from: d) {
            items = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    private func persist() {
        let list = Array(items.values)
        let target = url
        Task.detached(priority: .utility) {
            if let d = try? JSONEncoder().encode(list) { try? d.write(to: target, options: .atomic) }
        }
    }

    // MARK: 查询

    var all: [FollowUp] { Array(items.values) }
    var open: [FollowUp] { items.values.filter { !$0.done } }
    var openCount: Int { open.count }
    var overdueCount: Int { open.filter(\.isOverdue).count }

    var summaryLine: String {
        let o = open
        if o.isEmpty { return tr("给邮件加旗标、提醒、截止日期或备注", "Flag mail, add reminders, deadlines or notes") }
        let today = o.filter { f in f.deadline.map { Calendar.current.isDateInToday($0) } ?? false }.count
        var parts = [tr("\(o.count) 项待跟进", "\(o.count) open")]
        if overdueCount > 0 { parts.append(tr("\(overdueCount) 项已逾期", "\(overdueCount) overdue")) }
        if today > 0 { parts.append(tr("\(today) 项今天到期", "\(today) due today")) }
        return parts.joined(separator: " · ")
    }

    func item(_ id: String) -> FollowUp? { items[id] }

    func item(account: UUID, folder: String, summary: MessageSummary) -> FollowUp? {
        items[FollowUp.makeId(account: account, folder: folder, summary: summary)]
    }

    // MARK: 修改

    func save(_ f: FollowUp) {
        var x = f
        x.updated = Date()
        if x.done && x.doneAt == nil { x.doneAt = Date() }
        if !x.done { x.doneAt = nil }
        if x.isEmpty && !x.done {
            remove(x.id)
            return
        }
        items[x.id] = x
        persist()
        Notifier.schedule(x)
    }

    func remove(_ id: String) {
        guard let old = items.removeValue(forKey: id) else { return }
        persist()
        Notifier.cancel(old)
    }

    func setDone(_ id: String, _ done: Bool) {
        guard var f = items[id] else { return }
        f.done = done
        save(f)
    }

    /// 打开邮件后用最新的信息更新快照（例如邮件被移动后 UID 变了）。
    func refreshSummary(_ id: String, folder: String, summary: MessageSummary) {
        guard var f = items[id] else { return }
        var s = summary
        s.preview = s.preview ?? f.summary.preview
        f.summary = s
        f.folder = folder
        items[id] = f
        persist()
    }

    /// 把服务器上已加旗标、但这里还没有的邮件导入进来。
    func importServerFlags(_ a: MailAccount, folder: String, messages: [MessageSummary]) -> Int {
        var added = 0
        for m in messages {
            let id = FollowUp.makeId(account: a.id, folder: folder, summary: m)
            if items[id] != nil { continue }
            items[id] = FollowUp(id: id, accountId: a.id, folder: folder, summary: m)
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    // MARK: 通知

    enum Notifier {
        static func schedule(_ f: FollowUp) {
            let center = UNUserNotificationCenter.current()
            cancel(f)
            guard !f.done else { return }
            var reqs: [UNNotificationRequest] = []
            if let r = f.reminder, r > Date() {
                reqs.append(request(f, id: "fu-r-" + f.id, at: r,
                                    title: tr("提醒：", "Reminder: ") + f.subject))
            }
            if let d = f.deadline, d > Date() {
                reqs.append(request(f, id: "fu-d-" + f.id, at: d,
                                    title: tr("今天截止：", "Due: ") + f.subject))
            }
            guard !reqs.isEmpty else { return }
            Task {
                let ok = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                guard ok else { return }
                for r in reqs { try? await center.add(r) }
            }
        }

        static func cancel(_ f: FollowUp) {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["fu-r-" + f.id, "fu-d-" + f.id])
        }

        private static func request(_ f: FollowUp, id: String, at date: Date, title: String) -> UNNotificationRequest {
            let c = UNMutableNotificationContent()
            c.title = title
            var body = f.sender.isEmpty ? "" : f.sender
            if !f.note.isEmpty { body += (body.isEmpty ? "" : " · ") + f.note }
            c.body = body
            c.sound = .default
            c.threadIdentifier = "followups"
            c.userInfo = ["followUp": f.id]
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return UNNotificationRequest(identifier: id, content: c,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        }
    }
}

// MARK: - iOS 提醒事项

enum RemindersBridge {
    static let store = EKEventStore()

    static func requestAccess() async -> Bool {
        if #available(iOS 17.0, *) {
            return (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            return await withCheckedContinuation { cont in
                store.requestAccess(to: .reminder) { ok, _ in cont.resume(returning: ok) }
            }
        }
    }

    /// 新建或更新“提醒事项”里的一条，返回它的标识。
    static func upsert(_ f: FollowUp) async throws -> String {
        guard await requestAccess() else {
            throw MailError.protocolError(tr("没有访问“提醒事项”的权限。请到 iOS 设置 → RetroMail 里打开。",
                                             "No access to Reminders. Allow it in iOS Settings → RetroMail."))
        }
        let r: EKReminder
        if let id = f.reminderItemId, let old = store.calendarItem(withIdentifier: id) as? EKReminder {
            r = old
        } else {
            r = EKReminder(eventStore: store)
            guard let cal = store.defaultCalendarForNewReminders() else {
                throw MailError.protocolError(tr("没有可用的提醒事项列表。", "No Reminders list is available."))
            }
            r.calendar = cal
        }
        r.title = f.subject
        var notes = [tr("发件人：", "From: ") + f.sender]
        if !f.note.isEmpty { notes.append(f.note) }
        notes.append(tr("来自 RetroMail", "From RetroMail"))
        r.notes = notes.joined(separator: "\n")
        r.isCompleted = f.done
        r.priority = f.priority == .high ? 1 : f.priority == .low ? 9 : 5
        if let d = f.deadline {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        } else {
            r.dueDateComponents = nil
        }
        r.alarms?.forEach { r.removeAlarm($0) }
        if let rem = f.reminder { r.addAlarm(EKAlarm(absoluteDate: rem)) }
        try store.save(r, commit: true)
        return r.calendarItemIdentifier
    }
}
