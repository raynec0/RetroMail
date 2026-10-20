import Foundation

enum MailSecurity: String, Codable, CaseIterable, Identifiable {
    case ssl, starttls, none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ssl: return "SSL/TLS"
        case .starttls: return "STARTTLS"
        case .none: return tr("不加密", "None")
        }
    }
}

struct ServerConfig {
    var host: String
    var port: Int
    var security: MailSecurity
    var username: String
    var password: String
    var allowInsecure: Bool
}

enum MailError: LocalizedError {
    case connection(String)
    case protocolError(String)
    case auth(String)
    case server(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .connection(let m): return tr("连接失败：", "Connection failed: ") + m
        case .protocolError(let m): return m
        case .auth(let m): return tr("登录失败：", "Sign-in failed: ") + m + "\n" + tr("请检查用户名和密码（部分邮箱需要使用“客户端授权码”）。", "Check the username and password (some providers require an app-specific password).")
        case .server(let m): return tr("服务器返回错误：", "Server error: ") + m
        case .closed: return tr("连接已被服务器关闭，请重试。", "The server closed the connection. Please try again.")
        }
    }

    var isConnectionError: Bool {
        switch self {
        case .connection, .closed: return true
        default: return false
        }
    }
}

/// 基于 URLSessionStreamTask 的 TCP 连接，支持直接 TLS 与 STARTTLS 升级。
final class MailSocket: NSObject, URLSessionStreamDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var task: URLSessionStreamTask?
    private var buffer = Data()
    private let allowInsecure: Bool
    private var isClosed = false
    var readTimeout: TimeInterval = 45

    init(host: String, port: Int, allowInsecure: Bool) {
        self.allowInsecure = allowInsecure
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 24 * 3600
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        let t = s.streamTask(withHostName: host, port: port)
        task = t
        t.resume()
    }

    func startTLS() {
        task?.startSecureConnection()
    }

    /// 必须调用：URLSession 会强引用 delegate，直到 invalidate。
    func close() {
        guard !isClosed else { return }
        isClosed = true
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    private func readChunk() async throws {
        guard let t = task, !isClosed else { throw MailError.closed }
        let timeout = readTimeout
        let result: (Data?, Bool) = try await withCheckedThrowingContinuation { cont in
            t.readData(ofMinLength: 1, maxLength: 256 * 1024, timeout: timeout) { data, atEOF, error in
                if let error = error {
                    cont.resume(throwing: MailError.connection(error.localizedDescription))
                } else {
                    cont.resume(returning: (data, atEOF))
                }
            }
        }
        if let d = result.0, !d.isEmpty {
            buffer.append(d)
        } else if result.1 {
            throw MailError.closed
        }
    }

    /// 读取一行（不含 CRLF）。
    func readLine() async throws -> Data {
        let crlf = Data([13, 10])
        var searchFrom = 0
        while true {
            if searchFrom < buffer.count, let r = buffer.range(of: crlf, in: searchFrom..<buffer.count) {
                let line = buffer.subdata(in: 0..<r.lowerBound)
                buffer = buffer.subdata(in: r.upperBound..<buffer.count)
                return line
            }
            searchFrom = max(0, buffer.count - 1)
            try await readChunk()
        }
    }

    func readBytes(_ n: Int) async throws -> Data {
        while buffer.count < n {
            try await readChunk()
        }
        let d = buffer.subdata(in: 0..<n)
        buffer = buffer.subdata(in: n..<buffer.count)
        return d
    }

    func write(_ data: Data) async throws {
        guard let t = task, !isClosed else { throw MailError.closed }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            t.write(data, timeout: max(30, Double(data.count) / 50_000)) { error in
                if let error = error {
                    cont.resume(throwing: MailError.connection(error.localizedDescription))
                } else {
                    cont.resume()
                }
            }
        }
    }

    func write(_ string: String) async throws {
        try await write(Data(string.utf8))
    }

    // MARK: - TLS 证书校验（可选：允许自签名证书）

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        _ completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if allowInsecure,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completion(.useCredential, URLCredential(trust: trust))
        } else {
            completion(.performDefaultHandling, nil)
        }
    }
}

/// 简单的异步互斥锁，保证同一连接上的 IMAP 命令严格串行。
actor AsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }

    func unlock() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
