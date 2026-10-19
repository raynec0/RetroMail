import Foundation

// MARK: - 账户

struct MailAccount: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var email = ""
    var imapHost = ""
    var imapPort = 993
    var imapSecurity: MailSecurity = .ssl
    var imapUser = ""
    var smtpHost = ""
    var smtpPort = 465
    var smtpSecurity: MailSecurity = .ssl
    var smtpUser = ""
    var smtpSameAuth = true
    var allowInsecureTLS = false
    var saveToSent = true
    /// 纯文本签名（旧版本保存的；也用于邮件的纯文本部分）
    var signature = ""
    /// 富文本签名（HTML，可带格式、链接、Logo 图片）。可选字段：旧数据里没有也能正常读取
    var signatureRich: String?
    /// 新邮件是否自动加签名（nil = 是）
    var signatureOnNew: Bool?
    /// 回复/转发是否自动加签名（nil = 是）
    var signatureOnReply: Bool?

    var address: MailAddress { MailAddress(name: name, email: email) }

    var hasSignature: Bool {
        !(signatureRich ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 签名的 HTML（不含外层容器）
    var signatureBodyHTML: String {
        if let r = signatureRich, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return r }
        let plain = signature.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return "" }
        return "<div>--&nbsp;<br>" + HTMLText.escape(plain).replacingOccurrences(of: "\n", with: "<br>") + "</div>"
    }
    var imapKey: String { "\(id.uuidString).imap" }
    var smtpKey: String { "\(id.uuidString).smtp" }
    var title: String { name.isEmpty ? email : "\(name) <\(email)>" }

    private var loginUser: String { imapUser.isEmpty ? email : imapUser }

    func imapConfig(password: String? = nil) -> ServerConfig {
        ServerConfig(host: imapHost.trimmingCharacters(in: .whitespaces), port: imapPort, security: imapSecurity,
                     username: loginUser, password: password ?? Keychain.get(imapKey) ?? "",
                     allowInsecure: allowInsecureTLS)
    }

    func smtpConfig(imapPassword: String? = nil, smtpPassword: String? = nil) -> ServerConfig {
        let user = smtpSameAuth ? loginUser : (smtpUser.isEmpty ? email : smtpUser)
        let pass = smtpSameAuth
            ? (imapPassword ?? Keychain.get(imapKey) ?? "")
            : (smtpPassword ?? Keychain.get(smtpKey) ?? "")
        return ServerConfig(host: smtpHost.trimmingCharacters(in: .whitespaces), port: smtpPort, security: smtpSecurity,
                            username: user, password: pass, allowInsecure: allowInsecureTLS)
    }

    func isMine(_ email: String) -> Bool {
        email.caseInsensitiveCompare(self.email) == .orderedSame
    }
}

// MARK: - 地址

struct MailAddress: Codable, Hashable {
    var name: String
    var email: String

    var display: String { name.isEmpty ? email : name }
    var full: String { name.isEmpty ? email : "\(name) <\(email)>" }

    var mimeString: String {
        if name.isEmpty { return email }
        if HeaderCoding.needsEncoding(name) {
            return "\(HeaderCoding.encode(name, fold: false)) <\(email)>"
        }
        if name.rangeOfCharacter(from: CharacterSet(charactersIn: "()<>[]:;@\\,.\"")) != nil {
            return "\"\(name.replacingOccurrences(of: "\"", with: "'"))\" <\(email)>"
        }
        return "\(name) <\(email)>"
    }

    /// 解析 “张三 <a@b.com>, "Li, Si" <c@d.com>, e@f.com”。
    static func parseList(_ rawValue: String?) -> [MailAddress] {
        guard let raw = rawValue, !raw.isEmpty else { return [] }
        var items: [String] = []
        var cur = ""
        var inQuote = false
        var angle = 0
        for ch in raw {
            if ch == "\"" {
                inQuote.toggle()
            } else if !inQuote && ch == "<" {
                angle += 1
            } else if !inQuote && ch == ">" {
                angle = max(0, angle - 1)
            }
            if !inQuote && angle == 0 && (ch == "," || ch == ";") {
                items.append(cur)
                cur = ""
                continue
            }
            cur.append(ch)
        }
        items.append(cur)

        var out: [MailAddress] = []
        for item in items {
            var s = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            if let colon = s.firstIndex(of: ":") {
                let label = s[..<colon]
                if !label.contains("<") && !label.contains("@") && !label.contains("\"") {
                    s = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
                let email = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
                var name = String(s[..<lt]).trimmingCharacters(in: .whitespaces)
                name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                name = name.replacingOccurrences(of: "\\\"", with: "\"")
                guard email.contains("@") else { continue }
                out.append(MailAddress(name: HeaderCoding.decode(name).trimmingCharacters(in: .whitespaces), email: email))
            } else {
                var email = s
                var name = ""
                if let p = s.firstIndex(of: "("), let q = s.lastIndex(of: ")"), p < q {
                    name = String(s[s.index(after: p)..<q])
                    email = String(s[..<p])
                }
                email = email.trimmingCharacters(in: CharacterSet(charactersIn: "<> \"'"))
                guard email.contains("@"), !email.contains(" ") else { continue }
                out.append(MailAddress(name: HeaderCoding.decode(name), email: email))
            }
        }
        return out
    }

    /// 用户输入：允许中文逗号/分号分隔。
    static func parseInput(_ s: String) -> [MailAddress] {
        let normalized = s.replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "；", with: ",")
            .replacingOccurrences(of: "\n", with: ",")
        return parseList(normalized)
    }
}

// MARK: - 邮件摘要

struct MessageSummary: Codable, Identifiable, Hashable {
    var uid: Int
    var subject: String
    var from: MailAddress?
    var to: [MailAddress]
    var cc: [MailAddress]
    /// 信头 Date（发件人声称的发送时间）
    var date: Date
    /// 服务器收到时间（INTERNALDATE），用于排序，与 Outlook 一致
    var received: Date
    var flags: [String]
    var size: Int
    var hasAttachment: Bool
    var messageId: String?
    var inReplyTo: String?
    var references: [String]
    /// 列表里显示的正文预览（后台补取）
    var preview: String?
    var contentType: String?
    var transferEncoding: String?
    /// 不在当前列表所属文件夹里的邮件（例如并入收件箱会话的“已发送”回复），记下它真正所在的文件夹
    var folderPath: String?

    var id: Int { uid }

    func has(_ flag: String) -> Bool {
        flags.contains { $0.caseInsensitiveCompare(flag) == .orderedSame }
    }

    var seen: Bool { has("\\Seen") }
    var flagged: Bool { has("\\Flagged") }
    var answered: Bool { has("\\Answered") }

    mutating func set(_ flag: String, _ on: Bool) {
        flags.removeAll { $0.caseInsensitiveCompare(flag) == .orderedSame }
        if on { flags.append(flag) }
    }

    /// 新的在前：先比收到时间，再比 UID。
    static func newestFirst(_ a: MessageSummary, _ b: MessageSummary) -> Bool {
        if a.received != b.received { return a.received > b.received }
        return a.uid > b.uid
    }
}

extension MessageSummary {
    init(uid: Int, headers h: MIMEHeaders, flags: [String], internalDate: Date?, size: Int) {
        self.uid = uid
        self.subject = HeaderCoding.decode(h["Subject"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.from = MailAddress.parseList(h["From"]).first
        self.to = MailAddress.parseList(h["To"])
        self.cc = MailAddress.parseList(h["Cc"])
        let headerDate = DateParsing.rfc2822(h["Date"])
        self.date = headerDate ?? internalDate ?? Date()
        self.received = internalDate ?? headerDate ?? Date()
        self.flags = flags
        self.size = size
        let ct = (h["Content-Type"] ?? "").lowercased()
        self.hasAttachment = ct.contains("multipart/mixed") || ct.contains("application/")
        self.messageId = Threading.ids(h["Message-ID"]).first
        self.inReplyTo = Threading.ids(h["In-Reply-To"]).first
        self.references = Threading.ids(h["References"])
        self.preview = nil
        self.contentType = h["Content-Type"]
        self.transferEncoding = h["Content-Transfer-Encoding"]
    }
}

// MARK: - 会话（同一主题的往来邮件）

struct Conversation: Identifiable, Hashable {
    /// 新的在前
    var messages: [MessageSummary]

    var id: String { "c" + String((own.isEmpty ? messages : own).map(\.uid).min() ?? 0) }
    var latest: MessageSummary { messages[0] }
    /// 属于当前文件夹的邮件（不含并入的“已发送”回复）
    var own: [MessageSummary] { messages.filter { $0.folderPath == nil } }
    var ownLatest: MessageSummary { own.first ?? messages[0] }
    /// 删除、移动、标记时只处理当前文件夹里的邮件
    var uids: [Int] { own.map(\.uid) }
    var unread: Int { own.filter { !$0.seen }.count }
    var includesMyReplies: Bool { messages.contains { $0.folderPath != nil } }
    var flagged: Bool { messages.contains { $0.flagged } }
    var hasAttachment: Bool { messages.contains { $0.hasAttachment } }
    var answered: Bool { latest.answered }
    var count: Int { messages.count }
    var subject: String { Threading.core(latest.subject).isEmpty ? latest.subject : Threading.core(latest.subject) }
}

enum Threading {
    private static let prefix = try! NSRegularExpression(
        pattern: "^\\s*((re|fw|fwd|aw|wg|sv|vs|tr|r|回复|答复|回覆|转发|轉寄|转寄|轉發)\\s*(\\[\\d+\\]|\\(\\d+\\))?\\s*[:：]\\s*)+",
        options: [.caseInsensitive])
    private static let idRegex = try! NSRegularExpression(pattern: "<[^<>\\s]+>")

    /// 去掉 Re:/回复：等前缀后的主题（保留大小写）。
    static func core(_ subject: String) -> String {
        let ns = subject as NSString
        let stripped = prefix.stringByReplacingMatches(in: subject, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 用于分组比较的主题键。
    static func key(_ subject: String) -> String {
        core(subject).lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 提取 <id@host> 列表（统一小写）。
    static func ids(_ raw: String?) -> [String] {
        guard let raw = raw, !raw.isEmpty else { return [] }
        let ns = raw as NSString
        let found = idRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).lowercased() }
        if found.isEmpty {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.contains("@") && !t.contains(" ") ? ["<" + t.lowercased() + ">"] : []
        }
        return found
    }

    /// 两封邮件是否属于同一会话。
    static func related(_ a: MessageSummary, _ b: MessageSummary) -> Bool {
        if let ida = a.messageId, b.references.contains(ida) || b.inReplyTo == ida { return true }
        if let idb = b.messageId, a.references.contains(idb) || a.inReplyTo == idb { return true }
        let ka = key(a.subject)
        return !ka.isEmpty && ka == key(b.subject)
    }

    /// 按 Message-ID 引用链 + 主题把邮件分组（与 Outlook 的会话视图类似）。
    static func group(_ msgs: [MessageSummary]) -> [Conversation] {
        let n = msgs.count
        var parent = Array(0..<n)
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { r = parent[r] }
            var c = i
            while parent[c] != r { let next = parent[c]; parent[c] = r; c = next }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }
        var byId: [String: Int] = [:]
        for (i, m) in msgs.enumerated() {
            if let id = m.messageId { byId[id] = i }
        }
        var bySubject: [String: Int] = [:]
        for (i, m) in msgs.enumerated() {
            for ref in m.references + (m.inReplyTo.map { [$0] } ?? []) {
                if let j = byId[ref] { union(i, j) }
            }
            let k = key(m.subject)
            if !k.isEmpty {
                if let j = bySubject[k] { union(i, j) } else { bySubject[k] = i }
            }
        }
        var groups: [Int: [MessageSummary]] = [:]
        for (i, m) in msgs.enumerated() {
            groups[find(i), default: []].append(m)
        }
        return groups.values
            .map { Conversation(messages: $0.sorted(by: MessageSummary.newestFirst)) }
            .sorted { MessageSummary.newestFirst($0.latest, $1.latest) }
    }
}

// MARK: - 文件夹

enum FolderRole: String, Codable {
    case inbox, drafts, sent, junk, trash, archive, other

    var order: Int {
        switch self {
        case .inbox: return 0
        case .drafts: return 1
        case .sent: return 2
        case .junk: return 3
        case .trash: return 4
        case .archive: return 5
        case .other: return 6
        }
    }

    var icon: String {
        switch self {
        case .inbox: return "tray"
        case .drafts: return "doc.text"
        case .sent: return "paperplane"
        case .junk: return "xmark.bin"
        case .trash: return "trash"
        case .archive: return "archivebox"
        case .other: return "folder"
        }
    }
}

struct MailFolder: Codable, Identifiable, Hashable {
    var path: String
    var delimiter: String?
    var flags: [String]

    var id: String { path }

    var decodedPath: String { IMAPUTF7.decode(path) }

    var components: [String] {
        guard let d = delimiter, !d.isEmpty else { return [decodedPath] }
        let parts = decodedPath.components(separatedBy: d).filter { !$0.isEmpty }
        return parts.isEmpty ? [decodedPath] : parts
    }

    var depth: Int { max(0, components.count - 1) }
    var lastName: String { components.last ?? decodedPath }

    var selectable: Bool {
        !flags.contains { ["\\noselect", "\\nonexistent"].contains($0.lowercased()) }
    }

    private func hasFlag(_ f: String) -> Bool {
        flags.contains { $0.caseInsensitiveCompare(f) == .orderedSame }
    }

    var role: FolderRole {
        if path.uppercased() == "INBOX" { return .inbox }
        let n = lastName.lowercased()
        if hasFlag("\\Sent") || ["sent", "sent items", "sent messages", "sent mail", "已发送", "已发送邮件"].contains(n) { return .sent }
        if hasFlag("\\Drafts") || ["drafts", "draft", "草稿箱", "草稿"].contains(n) { return .drafts }
        if hasFlag("\\Trash") || ["trash", "deleted items", "deleted messages", "deleted", "已删除", "已删除邮件", "垃圾箱"].contains(n) { return .trash }
        if hasFlag("\\Junk") || ["junk", "spam", "junk e-mail", "junk email", "垃圾邮件", "广告邮件"].contains(n) { return .junk }
        if hasFlag("\\Archive") || ["archive", "archives", "归档"].contains(n) { return .archive }
        return .other
    }

    var displayName: String {
        switch role {
        case .inbox: return tr("收件箱", "Inbox")
        case .drafts: return tr("草稿箱", "Drafts")
        case .sent: return tr("已发送", "Sent")
        case .junk: return tr("垃圾邮件", "Junk")
        case .trash: return tr("已删除", "Trash")
        case .archive: return tr("归档", "Archive")
        case .other: return lastName
        }
    }

    static func sorted(_ list: [MailFolder]) -> [MailFolder] {
        list.sorted { a, b in
            if a.role.order != b.role.order { return a.role.order < b.role.order }
            return a.decodedPath.localizedStandardCompare(b.decodedPath) == .orderedAscending
        }
    }
}

// MARK: - 日期

enum DateParsing {
    private static let formatters: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yy HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss",
    ].map { fmt in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = fmt
        return f
    }

    private static let internalFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f
    }()

    static func rfc2822(_ s: String?) -> Date? {
        guard var t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if let p = t.firstIndex(of: "(") { t = String(t[..<p]).trimmingCharacters(in: .whitespaces) }
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        for f in formatters {
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    static func internalDate(_ s: String) -> Date? {
        internalFormatter.date(from: s.trimmingCharacters(in: .whitespaces))
    }
}

enum Fmt {
    private static var cache: [String: DateFormatter] = [:]
    private static let lock = NSLock()

    private static func string(_ d: Date, zh: String, en: String) -> String {
        let english = tr("zh", "en") == "en"
        let fmt = english ? en : zh
        lock.lock()
        defer { lock.unlock() }
        let key = fmt + (english ? "#en" : "#zh")
        let f: DateFormatter
        if let c = cache[key] {
            f = c
        } else {
            f = DateFormatter()
            f.locale = Locale(identifier: english ? "en_US" : "zh_CN")
            f.dateFormat = fmt
            cache[key] = f
        }
        return f.string(from: d)
    }

    static func short(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return string(d, zh: "HH:mm", en: "h:mm a") }
        if cal.isDateInYesterday(d) { return tr("昨天", "Yesterday") }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day, days < 7 {
            return string(d, zh: "EEE", en: "EEE")
        }
        if cal.isDate(d, equalTo: Date(), toGranularity: .year) { return string(d, zh: "M/d", en: "MMM d") }
        return string(d, zh: "yy/M/d", en: "M/d/yy")
    }

    /// 卡片标题栏用的短日期 + 时间：“17:12” / “昨天 17:12” / “10/12 17:12”
    static func compact(_ d: Date) -> String {
        let cal = Calendar.current
        let time = string(d, zh: "HH:mm", en: "h:mm a")
        if cal.isDateInToday(d) { return time }
        if cal.isDateInYesterday(d) { return tr("昨天 ", "Yesterday ") + time }
        if cal.isDate(d, equalTo: Date(), toGranularity: .year) { return string(d, zh: "M/d HH:mm", en: "MMM d, h:mm a") }
        return string(d, zh: "yy/M/d HH:mm", en: "M/d/yy h:mm a")
    }

    static func long(_ d: Date) -> String {
        string(d, zh: "yyyy年M月d日 EEE HH:mm", en: "EEE, MMM d, yyyy h:mm a")
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

extension Fmt {
    /// 工具栏状态文字：“已更新 13:01” / “Updated 1:01 PM”
    static func updated(_ d: Date?) -> String {
        guard let d = d else { return "" }
        return tr("已更新 ", "Updated ") + short(d)
    }
}
