import Foundation

/// 一条 IMAP 连接。非线程安全，只能在 IMAPClient 的锁内使用。
final class IMAPConnection: @unchecked Sendable {
    enum Part {
        case text(String)
        case literal(Data)
    }

    struct Response {
        var untagged: [Data]
        var text: String
    }

    let config: ServerConfig
    private var socket: MailSocket?
    private var tagCounter = 0
    private(set) var capabilities: Set<String> = []
    private(set) var selected: String?
    private(set) var selectedExists = 0

    static let summaryItems = "(UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID CONTENT-TYPE IN-REPLY-TO REFERENCES)])"

    init(config: ServerConfig) {
        self.config = config
    }

    deinit {
        socket?.close()
    }

    // MARK: - 连接与登录

    func connect() async throws {
        guard !config.host.isEmpty else { throw MailError.protocolError(tr("未填写收件服务器地址", "Incoming server is not set")) }
        let s = MailSocket(host: config.host, port: config.port, allowInsecure: config.allowInsecure)
        socket = s
        if config.security == .ssl { s.startTLS() }

        let greetingData = try await readResponse()
        let greeting = String(decoding: greetingData, as: UTF8.self)
        let upperGreeting = greeting.uppercased()
        guard upperGreeting.hasPrefix("* OK") || upperGreeting.hasPrefix("* PREAUTH") else {
            throw MailError.protocolError(tr("服务器问候异常：", "Unexpected server greeting: ") + greeting)
        }
        try await refreshCapabilities()

        if config.security == .starttls {
            guard capabilities.contains("STARTTLS") else {
                throw MailError.protocolError(tr("该服务器不支持 STARTTLS，请改用 SSL/TLS 或不加密。", "This server does not support STARTTLS. Use SSL/TLS or no encryption."))
            }
            try await run("STARTTLS")
            s.startTLS()
            try await refreshCapabilities()
        }

        if !upperGreeting.hasPrefix("* PREAUTH") {
            try await login()
            try await refreshCapabilities()
        }

        // 网易等服务器要求客户端发送 ID 命令，否则会拒绝访问。
        if capabilities.contains("ID") {
            _ = try? await run("ID (\"name\" \"RetroMail\" \"version\" \"1.0\" \"vendor\" \"RetroMail\")")
        }
    }

    func close() {
        socket?.close()
        socket = nil
        selected = nil
    }

    func setReadTimeout(_ t: TimeInterval) {
        socket?.readTimeout = t
    }

    func logout() async {
        socket?.readTimeout = 5
        _ = try? await run("LOGOUT")
        close()
    }

    private func login() async throws {
        do {
            if capabilities.contains("LOGINDISABLED") && capabilities.contains("AUTH=PLAIN") {
                try await authenticatePlain()
            } else {
                try await run([.text("LOGIN "), Self.astring(config.username), .text(" "), Self.astring(config.password)])
            }
        } catch MailError.server(let msg) {
            throw MailError.auth(msg)
        }
    }

    private func authenticatePlain() async throws {
        guard let socket = socket else { throw MailError.closed }
        tagCounter += 1
        let tag = "A\(tagCounter)"
        let token = Data("\u{0}\(config.username)\u{0}\(config.password)".utf8).base64EncodedString()
        try await socket.write("\(tag) AUTHENTICATE PLAIN\r\n")
        while true {
            let r = try await readResponse()
            if r.first == 43 { break }
            if String(decoding: r, as: UTF8.self).hasPrefix(tag + " ") {
                throw MailError.server(String(decoding: r, as: UTF8.self))
            }
        }
        try await socket.write(token + "\r\n")
        while true {
            let lineData = try await readResponse()
            let line = String(decoding: lineData, as: UTF8.self)
            if line.hasPrefix(tag + " ") {
                if line.uppercased().hasPrefix(tag + " OK") { return }
                throw MailError.server(line)
            }
        }
    }

    private func refreshCapabilities() async throws {
        let r = try await run("CAPABILITY")
        var caps = Set<String>()
        for d in r.untagged {
            let s = String(decoding: d, as: UTF8.self)
            if s.uppercased().hasPrefix("* CAPABILITY") {
                for w in s.split(separator: " ").dropFirst(2) {
                    caps.insert(w.uppercased())
                }
            }
        }
        capabilities = caps
    }

    // MARK: - 底层收发

    private func readResponse() async throws -> Data {
        guard let socket = socket else { throw MailError.closed }
        var out = Data()
        while true {
            let line = try await socket.readLine()
            out.append(line)
            if let n = Self.trailingLiteral(line) {
                out.append(contentsOf: [13, 10])
                let literal = try await socket.readBytes(n)
                out.append(literal)
            } else {
                return out
            }
        }
    }

    private static func trailingLiteral(_ line: Data) -> Int? {
        guard let last = line.last, last == 125 else { return nil }
        guard let open = line.lastIndex(of: 123), open + 1 < line.count - 1 else { return nil }
        var s = String(decoding: line[(open + 1)..<(line.count - 1)], as: UTF8.self)
        if s.hasSuffix("+") { s.removeLast() }
        return Int(s)
    }

    @discardableResult
    func run(_ command: String) async throws -> Response {
        try await run([.text(command)])
    }

    @discardableResult
    func run(_ parts: [Part]) async throws -> Response {
        guard let socket = socket else { throw MailError.closed }
        tagCounter += 1
        let tag = String(format: "R%04d", tagCounter)
        let tagPrefix = Data((tag + " ").utf8)
        let literalPlus = capabilities.contains("LITERAL+")
        var untagged: [Data] = []
        var pending = Data(tagPrefix)

        for part in parts {
            switch part {
            case .text(let t):
                pending.append(Data(t.utf8))
            case .literal(let d):
                pending.append(Data("{\(d.count)\(literalPlus ? "+" : "")}\r\n".utf8))
                try await socket.write(pending)
                pending = Data()
                if !literalPlus {
                    while true {
                        let r = try await readResponse()
                        if r.first == 43 { break } // "+" 继续
                        if r.starts(with: tagPrefix) {
                            throw MailError.server(Self.statusMessage(r, prefixCount: tagPrefix.count))
                        }
                        untagged.append(r)
                    }
                }
                try await socket.write(d)
            }
        }
        pending.append(contentsOf: [13, 10])
        try await socket.write(pending)

        while true {
            let r = try await readResponse()
            if r.starts(with: tagPrefix) {
                let rest = String(decoding: r.subdata(in: tagPrefix.count..<r.count), as: UTF8.self)
                if rest.uppercased().hasPrefix("OK") {
                    return Response(untagged: untagged, text: rest)
                }
                throw MailError.server(Self.statusMessage(r, prefixCount: tagPrefix.count))
            }
            untagged.append(r)
        }
    }

    private static func statusMessage(_ r: Data, prefixCount: Int) -> String {
        let rest = String(decoding: r.subdata(in: min(prefixCount, r.count)..<r.count), as: UTF8.self)
        let comps = rest.split(separator: " ", maxSplits: 1)
        return comps.count > 1 ? String(comps[1]) : rest
    }

    static func astring(_ s: String) -> Part {
        if s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7f }) {
            let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return .text("\"" + escaped + "\"")
        }
        return .literal(Data(s.utf8))
    }

    static func uidSet(_ uids: [Int]) -> String {
        let s = Array(Set(uids)).sorted()
        var parts: [String] = []
        var i = 0
        while i < s.count {
            var j = i
            while j + 1 < s.count && s[j + 1] == s[j] + 1 { j += 1 }
            parts.append(i == j ? "\(s[i])" : "\(s[i]):\(s[j])")
            i = j + 1
        }
        return parts.joined(separator: ",")
    }

    // MARK: - 文件夹

    func listFolders() async throws -> [MailFolder] {
        let r = try await run("LIST \"\" \"*\"")
        var folders: [MailFolder] = []
        var seen = Set<String>()
        for d in r.untagged {
            let v = IMAPParser.parse(d)
            guard v.count >= 5, v[1].string?.uppercased() == "LIST", let flags = v[2].list else { continue }
            guard let path = v[4].string, !path.isEmpty, !seen.contains(path) else { continue }
            seen.insert(path)
            folders.append(MailFolder(path: path, delimiter: v[3].string, flags: flags.compactMap { $0.string }))
        }
        return folders
    }

    func status(_ path: String) async throws -> (unseen: Int, uidNext: Int) {
        let r = try await run([.text("STATUS "), Self.astring(path), .text(" (UNSEEN UIDNEXT)")])
        for d in r.untagged {
            let v = IMAPParser.parse(d)
            guard v.count >= 4, v[1].string?.uppercased() == "STATUS", let l = v.last?.list else { continue }
            var unseen = 0
            var next = 0
            var k = 0
            while k + 1 < l.count {
                let key = l[k].string?.uppercased()
                let n = Int(l[k + 1].string ?? "") ?? 0
                if key == "UNSEEN" { unseen = n } else if key == "UIDNEXT" { next = n }
                k += 2
            }
            return (unseen, next)
        }
        return (0, 0)
    }

    @discardableResult
    func select(_ path: String, force: Bool = false) async throws -> Int {
        if !force, selected == path { return selectedExists }
        selected = nil
        let r = try await run([.text("SELECT "), Self.astring(path)])
        var exists = 0
        for d in r.untagged {
            let comps = String(decoding: d, as: UTF8.self).uppercased().split(separator: " ")
            if comps.count >= 3, comps[2] == "EXISTS", let n = Int(comps[1]) { exists = n }
        }
        selected = path
        selectedExists = exists
        return exists
    }

    // MARK: - 邮件列表

    func fetchLatest(_ path: String, limit: Int) async throws -> (messages: [MessageSummary], hasMore: Bool) {
        let exists = try await select(path, force: true)
        guard exists > 0 else { return ([], false) }
        let start = max(1, exists - limit + 1)
        let r = try await run("FETCH \(start):\(exists) \(Self.summaryItems)")
        return (Self.parseSummaries(r.untagged), start > 1)
    }

    func fetchOlder(_ path: String, below uid: Int, limit: Int) async throws -> (messages: [MessageSummary], hasMore: Bool) {
        guard uid > 1 else { return ([], false) }
        try await select(path)
        let r = try await run("UID SEARCH UID 1:\(uid - 1)")
        var uids = Self.parseSearch(r.untagged).filter { $0 < uid }.sorted()
        let hasMore = uids.count > limit
        uids = Array(uids.suffix(limit))
        guard !uids.isEmpty else { return ([], false) }
        let f = try await run("UID FETCH \(Self.uidSet(uids)) \(Self.summaryItems)")
        return (Self.parseSummaries(f.untagged), hasMore)
    }

    func fetchSince(_ path: String, uid: Int) async throws -> [MessageSummary] {
        try await select(path, force: true)
        let r = try await run("UID FETCH \(uid):* \(Self.summaryItems)")
        return Self.parseSummaries(r.untagged).filter { $0.uid >= uid }
    }

    func search(_ path: String, query: String, limit: Int) async throws -> [MessageSummary] {
        try await select(path)
        let ascii = query.unicodeScalars.allSatisfy { $0.isASCII }
        var parts: [Part] = [.text("UID SEARCH " + (ascii ? "" : "CHARSET UTF-8 ") + "OR OR SUBJECT ")]
        parts.append(Self.astring(query))
        parts.append(.text(" FROM "))
        parts.append(Self.astring(query))
        parts.append(.text(" TO "))
        parts.append(Self.astring(query))
        let r = try await run(parts)
        let uids = Array(Self.parseSearch(r.untagged).sorted().suffix(limit))
        guard !uids.isEmpty else { return [] }
        let f = try await run("UID FETCH \(Self.uidSet(uids)) \(Self.summaryItems)")
        return Self.parseSummaries(f.untagged)
    }

    /// 按主题查找同一会话的邮件（用于把“已发送”里的回复并入会话）。
    func searchSubject(_ path: String, subject: String, limit: Int) async throws -> [MessageSummary] {
        let q = String(subject.prefix(60))
        guard !q.isEmpty else { return [] }
        try await select(path)
        let ascii = q.unicodeScalars.allSatisfy { $0.isASCII }
        let r = try await run([.text("UID SEARCH " + (ascii ? "" : "CHARSET UTF-8 ") + "SUBJECT "), Self.astring(q)])
        let uids = Array(Self.parseSearch(r.untagged).sorted().suffix(limit))
        guard !uids.isEmpty else { return [] }
        let f = try await run("UID FETCH \(Self.uidSet(uids)) \(Self.summaryItems)")
        return Self.parseSummaries(f.untagged)
    }

    func fetchRaw(_ path: String, uid: Int) async throws -> Data {
        try await select(path)
        let r = try await run("UID FETCH \(uid) (UID BODY.PEEK[])")
        for d in r.untagged {
            let v = IMAPParser.parse(d)
            guard v.count >= 4, v[2].string?.uppercased() == "FETCH", let items = v[3].list else { continue }
            var body: Data?
            var u: Int?
            var k = 0
            while k + 1 < items.count {
                let key = (items[k].string ?? "").uppercased()
                if key == "UID" { u = Int(items[k + 1].string ?? "") }
                if key.hasPrefix("BODY[") { body = items[k + 1].data }
                k += 2
            }
            if let body = body, u == nil || u == uid { return body }
        }
        throw MailError.protocolError(tr("这封邮件已不存在（可能已在其他设备上删除）。", "This message no longer exists (it may have been deleted on another device)."))
    }

    static func parseSearch(_ untagged: [Data]) -> [Int] {
        var out: [Int] = []
        for d in untagged {
            let comps = String(decoding: d, as: UTF8.self).split(separator: " ")
            if comps.count >= 2, comps[1].uppercased() == "SEARCH" {
                out += comps.dropFirst(2).compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
        }
        return out
    }

    static func parseSummaries(_ untagged: [Data]) -> [MessageSummary] {
        var out: [MessageSummary] = []
        for d in untagged {
            let v = IMAPParser.parse(d)
            guard v.count >= 4, v[2].string?.uppercased() == "FETCH", let items = v[3].list else { continue }
            var uid: Int?
            var flags: [String] = []
            var internalDate: Date?
            var size = 0
            var header: Data?
            var k = 0
            while k + 1 < items.count {
                let key = (items[k].string ?? "").uppercased()
                let val = items[k + 1]
                if key == "UID" {
                    uid = Int(val.string ?? "")
                } else if key == "FLAGS" {
                    flags = (val.list ?? []).compactMap { $0.string }
                } else if key == "INTERNALDATE" {
                    internalDate = DateParsing.internalDate(val.string ?? "")
                } else if key == "RFC822.SIZE" {
                    size = Int(val.string ?? "") ?? 0
                } else if key.hasPrefix("BODY[") {
                    header = val.data
                }
                k += 2
            }
            guard let u = uid, let h = header else { continue }
            out.append(MessageSummary(uid: u, headers: MIMEHeaders.parse(h), flags: flags, internalDate: internalDate, size: size))
        }
        return out.sorted(by: MessageSummary.newestFirst)
    }

    // MARK: - 修改

    func store(_ path: String, uids: [Int], flag: String, add: Bool) async throws {
        guard !uids.isEmpty else { return }
        try await select(path)
        try await run("UID STORE \(Self.uidSet(uids)) \(add ? "+" : "-")FLAGS.SILENT (\(flag))")
    }

    func move(_ path: String, uids: [Int], to dest: String) async throws {
        guard !uids.isEmpty else { return }
        try await select(path)
        let set = Self.uidSet(uids)
        if capabilities.contains("MOVE") {
            try await run([.text("UID MOVE \(set) "), Self.astring(dest)])
        } else {
            try await run([.text("UID COPY \(set) "), Self.astring(dest)])
            try await expunge(set)
        }
    }

    func delete(_ path: String, uids: [Int], trash: String?) async throws {
        guard !uids.isEmpty else { return }
        if let trash = trash, trash != path {
            try await move(path, uids: uids, to: trash)
        } else {
            try await select(path)
            try await expunge(Self.uidSet(uids))
        }
    }

    private func expunge(_ set: String) async throws {
        try await run("UID STORE \(set) +FLAGS.SILENT (\\Deleted)")
        if capabilities.contains("UIDPLUS") {
            try await run("UID EXPUNGE \(set)")
        } else {
            try await run("EXPUNGE")
        }
    }

    func append(_ path: String, message: Data, flags: String) async throws {
        try await run([.text("APPEND "), Self.astring(path), .text(" (\(flags)) "), .literal(message)])
    }
}

/// 一条 IMAP 连接的客户端：串行执行命令，闲置后先探活，断线自动重连一次。
/// MailCenter 为每个账户开多条（交互 / 列表 / 后台），互不阻塞。
final class IMAPClient: @unchecked Sendable {
    private let config: ServerConfig
    private let lock = AsyncLock()
    private var connection: IMAPConnection?
    private var lastUsed = Date.distantPast

    /// 超过这个时间没用过的连接，先发 NOOP 确认还活着（手机切后台后连接常被静默断开）。
    static let idleProbeAfter: TimeInterval = 120

    init(config: ServerConfig) {
        self.config = config
    }

    func perform<T>(_ op: (IMAPConnection) async throws -> T) async throws -> T {
        await lock.lock()
        do {
            let r = try await attempt(op)
            lastUsed = Date()
            await lock.unlock()
            return r
        } catch {
            await lock.unlock()
            throw error
        }
    }

    /// 预先建立连接并登录，后续操作无需等待握手。
    func warm() async {
        _ = try? await perform { _ in true }
    }

    private func attempt<T>(_ op: (IMAPConnection) async throws -> T) async throws -> T {
        var retried = false
        if let c = connection, Date().timeIntervalSince(lastUsed) > Self.idleProbeAfter {
            c.setReadTimeout(8)
            do {
                try await c.run("NOOP")
                c.setReadTimeout(45)
            } catch {
                c.close()
                connection = nil
            }
        }
        while true {
            let conn: IMAPConnection
            if let c = connection {
                conn = c
            } else {
                let c = IMAPConnection(config: config)
                do {
                    try await c.connect()
                } catch {
                    c.close()
                    throw error
                }
                connection = c
                conn = c
                retried = true
            }
            do {
                return try await op(conn)
            } catch let e as MailError where e.isConnectionError {
                conn.close()
                connection = nil
                if retried { throw e }
                retried = true
            }
        }
    }

    func shutdown() async {
        await lock.lock()
        if let c = connection {
            await c.logout()
        }
        connection = nil
        await lock.unlock()
    }
}
