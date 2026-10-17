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
    var signature = ""

    var address: MailAddress { MailAddress(name: name, email: email) }
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
    var date: Date
    var flags: [String]
    var size: Int
    var hasAttachment: Bool
    var messageId: String?

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
}

extension MessageSummary {
    init(uid: Int, headers h: MIMEHeaders, flags: [String], internalDate: Date?, size: Int) {
        self.uid = uid
        self.subject = HeaderCoding.decode(h["Subject"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.from = MailAddress.parseList(h["From"]).first
        self.to = MailAddress.parseList(h["To"])
        self.cc = MailAddress.parseList(h["Cc"])
        self.date = DateParsing.rfc2822(h["Date"]) ?? internalDate ?? Date()
        self.flags = flags
        self.size = size
        let ct = (h["Content-Type"] ?? "").lowercased()
        self.hasAttachment = ct.contains("multipart/mixed") || ct.contains("application/")
        self.messageId = h["Message-ID"]
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
        case .inbox: return "收件箱"
        case .drafts: return "草稿箱"
        case .sent: return "已发送"
        case .junk: return "垃圾邮件"
        case .trash: return "已删除"
        case .archive: return "归档"
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
    private static func formatter(_ fmt: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = fmt
        return f
    }

    private static let time = formatter("HH:mm")
    private static let monthDay = formatter("M/d")
    private static let full = formatter("yy/M/d")
    private static let longF = formatter("yyyy年M月d日 HH:mm")

    static func short(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return time.string(from: d) }
        if cal.isDateInYesterday(d) { return "昨天" }
        if cal.isDate(d, equalTo: Date(), toGranularity: .year) { return monthDay.string(from: d) }
        return full.string(from: d)
    }

    static func long(_ d: Date) -> String { longF.string(from: d) }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
