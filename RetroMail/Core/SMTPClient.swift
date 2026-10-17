import Foundation

final class SMTPClient {
    let config: ServerConfig
    private var socket: MailSocket?

    init(config: ServerConfig) {
        self.config = config
    }

    deinit {
        socket?.close()
    }

    /// 只连接并登录，用于“测试连接”。
    func verify() async throws {
        defer { close() }
        try await open()
        _ = try? await expect("QUIT", [221])
    }

    func send(_ message: Data, from: String, to recipients: [String]) async throws {
        defer { close() }
        try await open()
        _ = try await expect("MAIL FROM:<\(from)>", [250])
        for r in recipients {
            _ = try await expect("RCPT TO:<\(r)>", [250, 251], label: tr("收件人 ", "recipient ") + r)
        }
        _ = try await expect("DATA", [354])
        try await socket?.write(Self.dotStuff(message))
        _ = try await expect(".", [250], label: "DATA")
        _ = try? await expect("QUIT", [221])
    }

    private func close() {
        socket?.close()
        socket = nil
    }

    private func open() async throws {
        guard !config.host.isEmpty else { throw MailError.protocolError(tr("未填写发件服务器地址", "Outgoing server is not set")) }
        let s = MailSocket(host: config.host, port: config.port, allowInsecure: config.allowInsecure)
        socket = s
        if config.security == .ssl { s.startTLS() }
        _ = try await expect(nil, [220], label: "CONNECT")
        var ehlo = try await expect("EHLO [127.0.0.1]", [250])
        if config.security == .starttls {
            _ = try await expect("STARTTLS", [220])
            s.startTLS()
            ehlo = try await expect("EHLO [127.0.0.1]", [250])
        }
        try await authenticate(ehlo: ehlo)
    }

    private func authenticate(ehlo: String) async throws {
        guard !config.username.isEmpty else { return }
        var mechs = Set<String>()
        for line in ehlo.uppercased().split(separator: "\n") {
            let body = line.dropFirst(4)
            if body.hasPrefix("AUTH") {
                for m in body.dropFirst(4).split(whereSeparator: { $0 == " " || $0 == "=" }) {
                    mechs.insert(String(m).trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        do {
            if mechs.contains("PLAIN") || !mechs.contains("LOGIN") {
                let token = Data("\u{0}\(config.username)\u{0}\(config.password)".utf8).base64EncodedString()
                _ = try await expect("AUTH PLAIN \(token)", [235], label: "AUTH PLAIN")
            } else {
                _ = try await expect("AUTH LOGIN", [334])
                _ = try await expect(Data(config.username.utf8).base64EncodedString(), [334], label: "USER")
                _ = try await expect(Data(config.password.utf8).base64EncodedString(), [235], label: "PASS")
            }
        } catch MailError.server(let m) {
            throw MailError.auth(m)
        }
    }

    private func readReply() async throws -> (Int, String) {
        guard let socket = socket else { throw MailError.closed }
        var lines: [String] = []
        while true {
            let raw = try await socket.readLine()
            let l = String(decoding: raw, as: UTF8.self)
            lines.append(l)
            let chars = Array(l)
            if chars.count < 4 || chars[3] != "-" {
                let code = Int(String(chars.prefix(3))) ?? 0
                return (code, lines.joined(separator: "\n"))
            }
        }
    }

    private func expect(_ command: String?, _ codes: Set<Int>, label: String? = nil) async throws -> String {
        if let command = command {
            guard let socket = socket else { throw MailError.closed }
            try await socket.write(command + "\r\n")
        }
        let (code, text) = try await readReply()
        guard codes.contains(code) else {
            throw MailError.server("SMTP（\(label ?? command ?? "")）\(text)")
        }
        return text
    }

    static func dotStuff(_ d: Data) -> Data {
        var out = Data()
        out.reserveCapacity(d.count + 256)
        var atLineStart = true
        for b in d {
            if atLineStart && b == 46 { out.append(46) }
            out.append(b)
            atLineStart = (b == 10)
        }
        if out.suffix(2) != Data([13, 10]) {
            out.append(contentsOf: [13, 10])
        }
        return out
    }
}
