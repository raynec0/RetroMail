import Foundation
import SwiftUI
import UIKit
import AuthenticationServices
import CryptoKit
import Network
import Security

/// 用 ChatGPT 账号登录并直接使用订阅额度（Plus / Pro / Team / Business / Enterprise）。
///
/// 和 Minis、OpenClaw、opencode 一样，走 Codex 的登录方式：OpenAI 把 Codex 当作自家应用，
/// Team / 企业工作区登录时不需要管理员额外批准第三方应用；生成请求发到 ChatGPT 的 Codex 后端，
/// 用的是订阅里的 Codex 额度。OpenAI 明确支持在外部工具里这样使用订阅。
///
/// 两种登录方式：
/// 1. 网页登录：应用内打开 OpenAI 登录页，登录后跳回本机 http://127.0.0.1:1455/auth/callback（应用临时开一个只监听本机的小服务器接收）。
/// 2. 设备码登录：显示一个一次性代码，在任意浏览器打开 auth.openai.com/codex/device 输入即可（网页登录不顺时用）。
/// 令牌只保存在这台手机的钥匙串里。
@MainActor
final class ChatGPTAuth: NSObject, ObservableObject {
    static let shared = ChatGPTAuth()

    static let issuer = "https://auth.openai.com"
    static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let redirectURI = "http://127.0.0.1:1455/auth/callback"
    static let scope = "openid profile email offline_access"
    static let backend = "https://chatgpt.com/backend-api/codex"
    static let originator = "codex_cli_rs"
    static let clientVersion = "0.130.0"

    struct Credentials: Codable {
        var accessToken: String
        var refreshToken: String
        var idToken: String?
        var expiresAt: Date
        var email: String?
        var accountId: String?
        var plan: String?
        var workspace: String?
    }

    struct Model: Identifiable, Hashable {
        let id: String
        let name: String
    }

    struct DeviceCode: Equatable {
        let userCode: String
        let deviceAuthId: String
        let interval: Int
        let url: String
    }

    /// 拿不到模型列表时用的默认列表（来自 Codex 公开的模型清单）
    static let fallbackModels: [Model] = [
        Model(id: "gpt-5.5", name: "GPT-5.5"),
        Model(id: "gpt-6.1-sol", name: "GPT-6.1-Sol"),
        Model(id: "gpt-6-sol", name: "GPT-6-Sol"),
        Model(id: "gpt-6-luna", name: "GPT-6-Luna"),
        Model(id: "gpt-5.6-luna", name: "GPT-5.6-Luna"),
    ]

    @Published private(set) var credentials: Credentials?
    @Published private(set) var signingIn = false
    @Published private(set) var models: [Model] = []
    @Published private(set) var deviceCode: DeviceCode?
    @Published var status: String?

    private static let keychainKey = "chatgpt.codex.credentials"
    private static let legacyKey = "chatgpt.credentials"

    private var pending: (verifier: String, state: String)?
    private var session: ASWebAuthenticationSession?
    private var server: LoopbackServer?
    private var refreshTask: Task<Credentials, Error>?
    private var anchorProvider: AnchorProvider?
    private var devicePoll: Task<Void, Never>?

    override private init() {
        super.init()
        Keychain.delete(Self.legacyKey)   // 旧版（需要管理员批准的方式）留下的令牌
        if let s = Keychain.get(Self.keychainKey), let d = s.data(using: .utf8),
           let c = try? JSONDecoder().decode(Credentials.self, from: d) {
            credentials = c
        }
    }

    var isSignedIn: Bool { credentials != nil }

    nonisolated static var hasStoredCredentials: Bool { Keychain.get("chatgpt.codex.credentials") != nil }

    private func store(_ c: Credentials?) {
        credentials = c
        if let c = c, let d = try? JSONEncoder().encode(c) {
            Keychain.set(String(decoding: d, as: UTF8.self), for: Self.keychainKey)
        } else {
            Keychain.delete(Self.keychainKey)
        }
    }

    // MARK: 网页登录

    func signIn() {
        cancelSignIn()
        status = nil
        let verifier = Self.randomURLSafe(64)
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(32)
        pending = (verifier, state)

        let q: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", Self.clientId),
            ("redirect_uri", Self.redirectURI),
            ("scope", Self.scope),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("id_token_add_organizations", "true"),
            ("codex_cli_simplified_flow", "true"),
            ("state", state),
            ("originator", Self.originator),
        ]
        let query = q.map { "\($0.0)=\(Self.formEncode($0.1))" }.joined(separator: "&")
        guard let url = URL(string: Self.issuer + "/oauth/authorize?" + query) else { return }

        do {
            let srv = try LoopbackServer(port: 1455)
            srv.start { [weak self] target in
                Task { @MainActor in self?.handleCallback(target) }
            }
            server = srv
        } catch {
            status = tr("无法在本机 1455 端口接收登录结果。可以改用“设备码登录”，或登录后把浏览器里的网址粘贴回来。",
                        "Couldn't listen on port 1455. Use device-code sign-in, or paste the browser's address back here after signing in.")
        }

        signingIn = true
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] cbURL, _ in
            Task { @MainActor in
                if let u = cbURL { self?.handleCallback(u.absoluteString) }
            }
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first ?? UIWindow()
        let anchor = AnchorProvider(window)
        anchorProvider = anchor
        s.presentationContextProvider = anchor
        s.prefersEphemeralWebBrowserSession = false
        session = s
        s.start()
    }

    func cancelSignIn() {
        session?.cancel()
        session = nil
        server?.stop()
        server = nil
        devicePoll?.cancel()
        devicePoll = nil
        deviceCode = nil
        signingIn = false
    }

    /// 处理回调：可以是本机服务器收到的路径，也可以是用户粘贴的完整网址。
    func handleCallback(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = text.hasPrefix("/") ? "http://127.0.0.1:1455" + text : text
        guard let comps = URLComponents(string: full), comps.path.hasSuffix("/auth/callback") else {
            status = tr("这不是登录回调网址。", "That isn't the sign-in callback address.")
            return
        }
        let items = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let p = pending else { return }
        if let e = items["error"] {
            cancelSignIn()
            pending = nil
            status = e == "access_denied" ? tr("已取消登录。", "Sign-in was cancelled.") : tr("登录失败：", "Sign-in failed: ") + (items["error_description"] ?? e)
            return
        }
        guard items["state"] == p.state else {
            status = tr("登录状态校验失败，请重新登录。", "Sign-in state mismatch. Please try again.")
            return
        }
        guard let code = items["code"] else { return }
        pending = nil
        cancelSignIn()
        signingIn = true
        Task {
            defer { signingIn = false }
            await finishSignIn(code: code, verifier: p.verifier, redirect: Self.redirectURI)
        }
    }

    // MARK: 设备码登录

    func signInWithDeviceCode() {
        cancelSignIn()
        status = nil
        signingIn = true
        devicePoll = Task { [weak self] in
            guard let self = self else { return }
            do {
                var req = URLRequest(url: URL(string: Self.issuer + "/api/accounts/deviceauth/usercode")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": Self.clientId])
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let id = j["device_auth_id"] as? String,
                      let uc = (j["user_code"] as? String) ?? (j["usercode"] as? String) else {
                    throw AIError.unavailable(code == 404
                        ? tr("这个账号没有开启设备码登录，请用网页登录。", "Device-code sign-in isn't enabled; use browser sign-in.")
                        : tr("获取设备码失败（\(code)）。", "Couldn't get a device code (\(code))."))
                }
                let interval = Int("\(j["interval"] ?? "5")") ?? 5
                let dc = DeviceCode(userCode: uc, deviceAuthId: id, interval: max(2, interval), url: Self.issuer + "/codex/device")
                self.deviceCode = dc
                UIPasteboard.general.string = uc
                if let u = URL(string: dc.url) { await UIApplication.shared.open(u) }
                // 轮询，最多 15 分钟
                let start = Date()
                while !Task.isCancelled, Date().timeIntervalSince(start) < 900 {
                    try await Task.sleep(nanoseconds: UInt64(dc.interval) * 1_000_000_000)
                    var poll = URLRequest(url: URL(string: Self.issuer + "/api/accounts/deviceauth/token")!)
                    poll.httpMethod = "POST"
                    poll.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    poll.httpBody = try JSONSerialization.data(withJSONObject: ["device_auth_id": id, "user_code": uc])
                    let (pd, pr) = try await URLSession.shared.data(for: poll)
                    let st = (pr as? HTTPURLResponse)?.statusCode ?? 0
                    if st == 200, let pj = (try? JSONSerialization.jsonObject(with: pd)) as? [String: Any],
                       let authCode = pj["authorization_code"] as? String,
                       let verifier = pj["code_verifier"] as? String {
                        self.deviceCode = nil
                        await self.finishSignIn(code: authCode, verifier: verifier, redirect: Self.issuer + "/deviceauth/callback")
                        self.signingIn = false
                        return
                    }
                    if st != 403 && st != 404 {
                        throw AIError.unavailable(tr("设备码登录失败（\(st)）。", "Device-code sign-in failed (\(st))."))
                    }
                }
                if !Task.isCancelled {
                    self.status = tr("设备码已过期，请重新开始。", "The code expired. Please start again.")
                }
            } catch {
                if !Task.isCancelled { self.status = error.localizedDescription }
            }
            self.deviceCode = nil
            self.signingIn = false
        }
    }

    // MARK: 令牌

    private func finishSignIn(code: String, verifier: String, redirect: String) async {
        do {
            var req = URLRequest(url: URL(string: Self.issuer + "/oauth/token")!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.form([
                "grant_type": "authorization_code",
                "client_id": Self.clientId,
                "code": code,
                "redirect_uri": redirect,
                "code_verifier": verifier,
            ])
            let c = try await tokenRequest(req, previous: nil)
            store(c)
            var who = c.email ?? ""
            if let p = c.plan, !p.isEmpty { who += who.isEmpty ? p : " · " + p }
            status = tr("✓ 已登录 ChatGPT", "✓ Signed in to ChatGPT") + (who.isEmpty ? "" : "（\(who)）")
            await loadModels()
        } catch {
            status = error.localizedDescription
        }
    }

    private func tokenRequest(_ req: URLRequest, previous: Credentials?) async throws -> Credentials {
        var r = req
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard code == 200, let access = json["access_token"] as? String else {
            let errObj = json["error"] as? [String: Any]
            let errCode = (json["error"] as? String) ?? (errObj?["code"] as? String) ?? ""
            let msg = (json["error_description"] as? String) ?? (errObj?["message"] as? String) ?? (errCode.isEmpty ? String(decoding: data.prefix(300), as: UTF8.self) : errCode)
            if previous != nil, code == 400 || code == 401 {
                store(nil)
                throw AIError.unavailable(tr("ChatGPT 登录已过期，请到 AI 设置里重新登录。", "Your ChatGPT sign-in expired. Sign in again in AI settings."))
            }
            throw AIError.http(code, msg)
        }
        let idToken = json["id_token"] as? String ?? previous?.idToken
        let claims = idToken.flatMap(Self.claims(fromJWT:)) ?? [:]
        let accessClaims = Self.claims(fromJWT: access) ?? [:]
        let auth = (claims["https://api.openai.com/auth"] as? [String: Any]) ?? (accessClaims["https://api.openai.com/auth"] as? [String: Any]) ?? [:]
        let accountId = (auth["chatgpt_account_id"] as? String) ?? previous?.accountId
        var workspace: String?
        if let orgs = auth["organizations"] as? [[String: Any]] {
            workspace = orgs.first { ($0["id"] as? String) == accountId }?["title"] as? String
        }
        let expires = (json["expires_in"] as? NSNumber)?.doubleValue
            ?? ((accessClaims["exp"] as? NSNumber).map { $0.doubleValue - Date().timeIntervalSince1970 }) ?? 3600
        return Credentials(accessToken: access,
                           refreshToken: json["refresh_token"] as? String ?? previous?.refreshToken ?? "",
                           idToken: idToken,
                           expiresAt: Date().addingTimeInterval(expires),
                           email: (claims["email"] as? String) ?? previous?.email,
                           accountId: accountId,
                           plan: (auth["chatgpt_plan_type"] as? String) ?? previous?.plan,
                           workspace: workspace ?? previous?.workspace)
    }

    func signOut() {
        store(nil)
        models = []
        status = nil
    }

    /// 取一个有效的 access token（快过期时先刷新；同一时间只刷新一次）。
    func validToken() async throws -> Credentials {
        guard let c = credentials else {
            throw AIError.unavailable(tr("还没有登录 ChatGPT。请到 AI 设置里点“用 ChatGPT 登录”。", "Not signed in to ChatGPT. Use Sign in with ChatGPT in AI settings."))
        }
        if c.expiresAt.timeIntervalSinceNow > 300 { return c }
        return try await refresh()
    }

    @discardableResult
    func refresh() async throws -> Credentials {
        if let t = refreshTask { return try await t.value }
        guard let c = credentials, !c.refreshToken.isEmpty else {
            throw AIError.unavailable(tr("ChatGPT 登录已过期，请重新登录。", "ChatGPT sign-in expired. Please sign in again."))
        }
        let t = Task { () -> Credentials in
            var req = URLRequest(url: URL(string: Self.issuer + "/oauth/token")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "grant_type": "refresh_token",
                "client_id": Self.clientId,
                "refresh_token": c.refreshToken,
            ])
            return try await tokenRequest(req, previous: c)
        }
        refreshTask = t
        defer { refreshTask = nil }
        let fresh = try await t.value
        store(fresh)
        return fresh
    }

    // MARK: 模型与调用

    private func headers(_ c: Credentials, _ req: inout URLRequest) {
        req.setValue("Bearer \(c.accessToken)", forHTTPHeaderField: "Authorization")
        if let a = c.accountId { req.setValue(a, forHTTPHeaderField: "chatgpt-account-id") }
        req.setValue(Self.originator, forHTTPHeaderField: "originator")
        req.setValue("codex_cli_rs/\(Self.clientVersion) (iOS; RetroMail)", forHTTPHeaderField: "User-Agent")
    }

    func loadModels() async {
        guard let c = try? await validToken() else { return }
        var req = URLRequest(url: URL(string: Self.backend + "/models?client_version=\(Self.clientVersion)")!, timeoutInterval: 20)
        headers(c, &req)
        var out: [Model] = []
        if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = (json["models"] as? [[String: Any]]) ?? (json["data"] as? [[String: Any]]) {
            for m in list {
                if let v = m["visibility"] as? String, v != "list" { continue }
                guard let slug = (m["slug"] as? String) ?? (m["id"] as? String) else { continue }
                out.append(Model(id: slug, name: (m["display_name"] as? String) ?? slug))
            }
        }
        models = out.isEmpty ? Self.fallbackModels : out
    }

    /// 生成文字：Codex Responses 接口，流式读取。
    func complete(system: String, user: String, model: String?) async throws -> String {
        if models.isEmpty { await loadModels() }
        let modelId = (model?.isEmpty == false ? model! : nil) ?? models.first?.id ?? "gpt-5.5"
        var c = try await validToken()
        do {
            return try await stream(system: system, user: user, model: modelId, creds: c, reasoning: true)
        } catch AIError.http(401, _) {
            c = try await refresh()
            return try await stream(system: system, user: user, model: modelId, creds: c, reasoning: true)
        } catch AIError.http(400, let msg) where msg.lowercased().contains("reasoning") {
            return try await stream(system: system, user: user, model: modelId, creds: c, reasoning: false)
        }
    }

    private func stream(system: String, user: String, model: String, creds: Credentials, reasoning: Bool) async throws -> String {
        var req = URLRequest(url: URL(string: Self.backend + "/responses")!, timeoutInterval: 180)
        req.httpMethod = "POST"
        headers(creds, &req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "session_id")
        func message(_ role: String, _ text: String) -> [String: Any] {
            ["type": "message", "role": role, "content": [["type": "input_text", "text": text]]]
        }
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "instructions": system,
            "input": [message("user", user)],
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "store": false,
            "include": [String](),
        ]
        if reasoning { body["reasoning"] = ["effort": "low"] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            var raw = Data()
            for try await b in bytes { raw.append(b); if raw.count > 4000 { break } }
            let json = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? (json?["detail"] as? String)
                ?? String(decoding: raw.prefix(400), as: UTF8.self)
            if code == 400, msg.lowercased().contains("instructions") {
                // 个别模型不接受自定义 instructions：改为放进对话开头再试
                return try await streamWithoutInstructions(system: system, user: user, model: model, creds: creds)
            }
            if code == 429 {
                throw AIError.unavailable(tr("ChatGPT 订阅的用量暂时用完了，请稍后再试，或在 AI 设置里换一个模型。", "Your ChatGPT plan's usage limit was reached. Try later or pick another model."))
            }
            throw AIError.http(code, msg)
        }
        return try await readStream(bytes)
    }

    private func streamWithoutInstructions(system: String, user: String, model: String, creds: Credentials) async throws -> String {
        var req = URLRequest(url: URL(string: Self.backend + "/responses")!, timeoutInterval: 180)
        req.httpMethod = "POST"
        headers(creds, &req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "input": [
                ["type": "message", "role": "developer", "content": [["type": "input_text", "text": system]]],
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": user]]],
            ],
            "tool_choice": "auto",
            "parallel_tool_calls": false,
            "store": false,
            "include": [String](),
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            var raw = Data()
            for try await b in bytes { raw.append(b); if raw.count > 4000 { break } }
            throw AIError.http(code, String(decoding: raw.prefix(400), as: UTF8.self))
        }
        return try await readStream(bytes)
    }

    private func readStream(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var text = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let d = payload.data(using: .utf8),
                  let ev = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            let type = ev["type"] as? String ?? ""
            if type == "response.output_text.delta" {
                text += ev["delta"] as? String ?? ""
            } else if type == "response.output_text.done" {
                if text.isEmpty { text = ev["text"] as? String ?? "" }
            } else if type == "response.completed" {
                break
            } else if type == "response.failed" || type == "error" {
                let r = ev["response"] as? [String: Any]
                let err = (r?["error"] as? [String: Any]) ?? (ev["error"] as? [String: Any]) ?? ev
                let codeStr = (err["code"] as? String) ?? ""
                if codeStr.contains("usage_limit") || codeStr.contains("rate_limit") {
                    throw AIError.unavailable(tr("ChatGPT 订阅的用量暂时用完了，请稍后再试。", "Your ChatGPT plan's usage limit was reached. Try again later."))
                }
                throw AIError.unavailable((err["message"] as? String) ?? tr("ChatGPT 没有完成回答。", "ChatGPT didn't finish the response."))
            } else if type == "response.incomplete" {
                if !text.isEmpty { break }
                throw AIError.unavailable(tr("ChatGPT 的回答被截断了，请重试。", "ChatGPT's response was cut off. Please retry."))
            }
        }
        guard !text.isEmpty else { throw AIError.empty }
        return text
    }

    // MARK: 工具

    private static func randomURLSafe(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return base64url(Data(b))
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func form(_ dict: [String: String]) -> Data {
        Data(dict.map { "\($0.key)=\(formEncode($0.value))" }.joined(separator: "&").utf8)
    }

    static func claims(fromJWT jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    let window: UIWindow
    init(_ w: UIWindow) { window = w }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
}

/// 只监听本机的极简 HTTP 服务器，用来接收登录后的跳转。
final class LoopbackServer {
    private let listener: NWListener

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start(onCallback: @escaping (String) -> Void) {
        listener.newConnectionHandler = { conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let req = String(decoding: data ?? Data(), as: UTF8.self)
                let first = req.components(separatedBy: "\r\n").first ?? ""
                let parts = first.split(separator: " ")
                let target = parts.count >= 2 ? String(parts[1]) : ""
                let ok = target.hasPrefix("/auth/callback")
                let html = """
                <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
                <title>RetroMail</title></head><body style="font-family:-apple-system,Helvetica;text-align:center;padding:60px 20px;background:#C5CCD4">
                <h2>\(ok ? "✓ 已登录 ChatGPT" : "RetroMail")</h2><p>\(ok ? "可以关闭这个页面，回到 RetroMail。" : "")</p></body></html>
                """
                let body = Data(html.utf8)
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
                if ok { onCallback(target) }
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
    }
}

// MARK: - 设置界面

struct ChatGPTSignInGroup: View {
    @Binding var model: String
    @ObservedObject private var auth = ChatGPTAuth.shared
    @State private var pasted = ""

    var body: some View {
        RetroGroup(tr("ChatGPT 账号", "ChatGPT Account")) {
            HStack(spacing: 10) {
                Image("mbx-chat").resizable().interpolation(.high).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    if let c = auth.credentials {
                        Text(tr("已登录", "Signed in") + (c.plan.map { " · " + $0.capitalized } ?? "")).font(RT.font(15, .bold))
                        Text([c.email, c.workspace].compactMap { $0 }.joined(separator: " · "))
                            .font(RT.font(13)).foregroundColor(IOS3.value).lineLimit(1)
                    } else {
                        Text(tr("未登录", "Not signed in")).font(RT.font(15, .bold))
                        Text(tr("支持 Plus / Pro / Team / Business / Enterprise", "Plus / Pro / Team / Business / Enterprise"))
                            .font(RT.font(12)).foregroundColor(IOS3.secondary)
                    }
                }
                Spacer()
                if auth.signingIn {
                    ProgressView()
                } else if auth.isSignedIn {
                    Button(tr("退出", "Sign Out")) { auth.signOut() }
                        .buttonStyle(RetroButtonStyle(compact: true, destructive: true))
                }
            }
            .padding(12)

            if !auth.isSignedIn && !auth.signingIn {
                VStack(spacing: 8) {
                    Button(tr("用 ChatGPT 登录", "Sign in with ChatGPT")) { auth.signIn() }
                        .buttonStyle(RetroButtonStyle(isDefault: true))
                        .frame(maxWidth: .infinity)
                    Button(tr("设备码登录（网页登录不顺时用）", "Sign in with a Device Code")) { auth.signInWithDeviceCode() }
                        .buttonStyle(RetroButtonStyle(compact: true))
                }
                .padding(12)
            }

            if let dc = auth.deviceCode {
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("在打开的网页里登录 ChatGPT，然后输入下面的代码（已复制，可直接粘贴）：", "Sign in to ChatGPT in the page that opened, then enter this code (already copied):"))
                        .font(RT.font(12))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(dc.userCode)
                            .font(.system(size: 26, weight: .heavy, design: .monospaced))
                            .foregroundColor(IOS3.value)
                            .textSelection(.enabled)
                        Spacer()
                        Button(tr("复制", "Copy")) { UIPasteboard.general.string = dc.userCode }
                            .buttonStyle(RetroButtonStyle(compact: true))
                        Button(tr("打开网页", "Open")) {
                            if let u = URL(string: dc.url) { UIApplication.shared.open(u) }
                        }
                        .buttonStyle(RetroButtonStyle(compact: true))
                    }
                    Text(tr("输完后回到这里，会自动完成登录。代码 15 分钟内有效。", "Come back here afterwards; sign-in finishes automatically. The code is valid for 15 minutes."))
                        .font(RT.font(11)).opacity(0.75)
                    Button(tr("取消", "Cancel")) { auth.cancelSignIn() }
                        .buttonStyle(RetroButtonStyle(compact: true))
                }
                .padding(12)
            } else if auth.signingIn && !auth.isSignedIn {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("在弹出的页面里登录 ChatGPT（Team / 企业账号选择对应工作区）。完成后会自动回来；如果停在一个打不开的 127.0.0.1 页面，复制浏览器地址栏里的网址粘贴到这里：",
                            "Sign in to ChatGPT in the page that opens (pick your workspace for Team / Enterprise). It returns automatically; if it stops on a 127.0.0.1 page that won't load, copy that address and paste it here:"))
                        .font(RT.font(12))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("http://127.0.0.1:1455/auth/callback?code=…", text: $pasted)
                            .font(RT.font(12))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button(tr("完成", "Done")) {
                            auth.handleCallback(pasted)
                            pasted = ""
                        }
                        .buttonStyle(RetroButtonStyle(compact: true))
                        .disabled(pasted.isEmpty)
                    }
                    Button(tr("取消登录", "Cancel Sign-in")) { auth.cancelSignIn() }
                        .buttonStyle(RetroButtonStyle(compact: true))
                }
                .padding(12)
            }

            if auth.isSignedIn {
                HStack {
                    Text(tr("模型", "Model")).font(RT.font(15, .bold))
                    Spacer()
                    Menu {
                        Button(tr("自动（第一个可用）", "Automatic (first available)")) { model = "" }
                        ForEach(auth.models) { m in
                            Button(m.name) { model = m.id }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(model.isEmpty ? tr("自动", "Automatic") : (auth.models.first { $0.id == model }?.name ?? model))
                                .font(RT.font(14, .bold))
                                .foregroundColor(IOS3.value)
                                .lineLimit(1)
                            Text("▾").font(RT.font(12)).foregroundColor(IOS3.value)
                        }
                    }
                    Button(tr("刷新", "Refresh")) { Task { await auth.loadModels() } }
                        .buttonStyle(RetroButtonStyle(compact: true))
                }
                .padding(12)
                .task { if auth.models.isEmpty { await auth.loadModels() } }
            }

            if let s = auth.status {
                Text(s).font(RT.font(12)).foregroundColor(IOS3.groupHeader)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }

            Text(tr("和 Minis 一样使用 Codex 的登录方式：Team / 企业工作区不需要管理员额外批准。用的是你订阅里的 Codex 额度（不另外收费）。令牌只存在这台手机的钥匙串里，请求直接从手机发给 OpenAI。",
                    "Uses the same Codex sign-in as Minis, so Team / Enterprise workspaces don't need extra admin approval. Usage counts against your plan's Codex allowance (no extra charge). Tokens stay in this iPhone's Keychain and requests go straight to OpenAI."))
                .font(RT.font(11))
                .opacity(0.75)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }
}
