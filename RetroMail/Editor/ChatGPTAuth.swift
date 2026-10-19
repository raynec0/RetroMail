import Foundation
import SwiftUI
import UIKit
import AuthenticationServices
import CryptoKit
import Network
import Security

/// 用 ChatGPT 账号登录，直接使用你的 ChatGPT 订阅额度（OpenAI 官方的 “Sign in with ChatGPT” 开源 / 本地应用流程）。
///
/// 流程：浏览器打开 OpenAI 登录页 → 登录后跳回本机 http://127.0.0.1:1455/auth/callback（应用里临时开一个只监听本机的小服务器接收）
/// → 用授权码换 access token / refresh token → 调 https://api.openai.com/v1/responses。
/// 令牌只保存在本机钥匙串里。
@MainActor
final class ChatGPTAuth: NSObject, ObservableObject {
    static let shared = ChatGPTAuth()

    static let authorizeURL = "https://auth.openai.com/api/accounts/authorize"
    static let tokenURL = "https://auth.openai.com/api/accounts/oauth/token"
    static let resource = "https://api.openai.com/v1"
    static let redirectURI = "http://127.0.0.1:1455/auth/callback"
    static let scope = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"

    struct Credentials: Codable {
        var clientId: String
        var accessToken: String
        var refreshToken: String
        var idToken: String?
        var expiresAt: Date
        var email: String?
    }

    struct Model: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @Published private(set) var credentials: Credentials?
    @Published private(set) var signingIn = false
    @Published private(set) var models: [Model] = []
    @Published var status: String?

    private static let keychainKey = "chatgpt.credentials"
    private static let clientIdKey = "chatgpt.clientId"
    private static let hostIdKey = "chatgpt.hostId"

    private var pending: (verifier: String, state: String, nonce: String, firstTime: Bool)?
    private var session: ASWebAuthenticationSession?
    private var server: LoopbackServer?
    private var refreshTask: Task<Credentials, Error>?
    private var anchorProvider: AnchorProvider?

    override private init() {
        super.init()
        if let s = Keychain.get(Self.keychainKey), let d = s.data(using: .utf8),
           let c = try? JSONDecoder().decode(Credentials.self, from: d) {
            credentials = c
        }
    }

    var isSignedIn: Bool { credentials != nil }

    /// 本机固定的标识（OpenAI 要求同一设备每次登录都用同一个）
    private var hostId: String {
        if let h = UserDefaults.standard.string(forKey: Self.hostIdKey) { return h }
        let h = "urn:uuid:" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(h, forKey: Self.hostIdKey)
        return h
    }

    private func store(_ c: Credentials?) {
        credentials = c
        if let c = c, let d = try? JSONEncoder().encode(c) {
            Keychain.set(String(decoding: d, as: UTF8.self), for: Self.keychainKey)
            UserDefaults.standard.set(c.clientId, forKey: Self.clientIdKey)
        } else {
            Keychain.delete(Self.keychainKey)
        }
    }

    // MARK: 登录

    func signIn() {
        cancelSignIn()
        status = nil
        let verifier = Self.randomURLSafe(48)
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(24)
        let nonce = Self.randomURLSafe(24)
        let savedClient = UserDefaults.standard.string(forKey: Self.clientIdKey)
        pending = (verifier, state, nonce, savedClient == nil)

        var q: [URLQueryItem] = [
            .init(name: "client_id", value: savedClient ?? "dynamic_agent_client"),
            .init(name: "ext_agent_host_id", value: hostId),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "scope", value: Self.scope),
            .init(name: "resource", value: Self.resource),
            .init(name: "state", value: state),
            .init(name: "nonce", value: nonce),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
        ]
        if savedClient == nil {
            q.append(.init(name: "agent_name_hint", value: "RetroMail"))
        } else {
            if let id = credentials?.idToken { q.append(.init(name: "id_token_hint", value: id)) }
            if let e = credentials?.email { q.append(.init(name: "login_hint", value: e)) }
        }
        var comps = URLComponents(string: Self.authorizeURL)!
        // URLComponents 不会转义 “+”“/”等，这里统一按表单规则编码
        comps.percentEncodedQuery = q.map { "\($0.name)=\(Self.formEncode($0.value ?? ""))" }.joined(separator: "&")
        guard let url = comps.url else { return }

        do {
            let srv = try LoopbackServer(port: 1455)
            srv.start { [weak self] target in
                Task { @MainActor in self?.handleCallback(target) }
            }
            server = srv
        } catch {
            status = tr("无法在本机 1455 端口接收登录结果，可以登录后把浏览器里的网址粘贴回来。", "Couldn't listen on port 1455. After signing in, paste the browser's address back here.")
        }

        signingIn = true
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { [weak self] cbURL, _ in
            Task { @MainActor in
                if let u = cbURL { self?.handleCallback(u.absoluteString) }
                // 用户手动关掉了登录页：如果还没拿到结果就保持“等待粘贴”状态
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
        guard items["state"] == p.state else {
            status = tr("登录状态校验失败，请重新登录。", "Sign-in state mismatch. Please try again.")
            return
        }
        if let e = items["error"] {
            cancelSignIn()
            pending = nil
            status = e == "access_denied" ? tr("已取消登录。", "Sign-in was cancelled.") : tr("登录失败：", "Sign-in failed: ") + (items["error_description"] ?? e)
            return
        }
        guard let code = items["code"] else { return }
        let saved = UserDefaults.standard.string(forKey: Self.clientIdKey)
        let clientId: String
        if p.firstTime {
            guard let issued = items["client_id"], !issued.isEmpty else {
                status = tr("没有收到 OpenAI 分配的应用 ID，请重试。", "OpenAI didn't return a client ID. Please try again.")
                return
            }
            clientId = issued
        } else {
            if let issued = items["client_id"], let s = saved, issued != s {
                status = tr("登录结果与本机记录不符，请重试。", "The sign-in result doesn't match this device. Please try again.")
                return
            }
            clientId = saved ?? items["client_id"] ?? ""
        }
        pending = nil
        cancelSignIn()
        signingIn = true
        Task {
            defer { signingIn = false }
            do {
                let c = try await exchange(form: [
                    "grant_type": "authorization_code",
                    "client_id": clientId,
                    "code": code,
                    "code_verifier": p.verifier,
                    "redirect_uri": Self.redirectURI,
                    "resource": Self.resource,
                ], clientId: clientId, previous: nil)
                store(c)
                status = tr("✓ 已登录 ChatGPT", "✓ Signed in to ChatGPT") + (c.email.map { "（\($0)）" } ?? "")
                await loadModels()
            } catch {
                status = error.localizedDescription
            }
        }
    }

    func signOut() {
        let c = credentials
        store(nil)
        models = []
        guard let c = c else { return }
        Task {
            // 通知 OpenAI 作废这个令牌
            guard let conf = try? await URLSession.shared.data(from: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!).0,
                  let json = try? JSONSerialization.jsonObject(with: conf) as? [String: Any],
                  let rev = json["revocation_endpoint"] as? String, let url = URL(string: rev) else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.form(["token": c.refreshToken, "token_type_hint": "refresh_token", "client_id": c.clientId])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    // MARK: 令牌

    private func exchange(form: [String: String], clientId: String, previous: Credentials?) async throws -> Credentials {
        var req = URLRequest(url: URL(string: Self.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Self.form(form)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard code == 200, let access = json["access_token"] as? String else {
            let msg = (json["error_description"] as? String) ?? (json["error"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            if (json["error"] as? String) == "invalid_grant", previous != nil {
                store(nil)
                throw AIError.unavailable(tr("ChatGPT 登录已过期，请到 AI 设置里重新登录。", "Your ChatGPT sign-in expired. Sign in again in AI settings."))
            }
            throw AIError.http(code, msg)
        }
        let expires = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let idToken = json["id_token"] as? String ?? previous?.idToken
        return Credentials(clientId: clientId,
                           accessToken: access,
                           refreshToken: json["refresh_token"] as? String ?? previous?.refreshToken ?? "",
                           idToken: idToken,
                           expiresAt: Date().addingTimeInterval(expires),
                           email: idToken.flatMap(Self.email(fromJWT:)) ?? previous?.email)
    }

    /// 取一个有效的 access token（快过期时先刷新；同一时间只刷新一次）。
    func validToken() async throws -> String {
        guard let c = credentials else {
            throw AIError.unavailable(tr("还没有登录 ChatGPT。请到 AI 设置里点“用 ChatGPT 登录”。", "Not signed in to ChatGPT. Use Sign in with ChatGPT in AI settings."))
        }
        if c.expiresAt.timeIntervalSinceNow > 90 { return c.accessToken }
        return try await refresh().accessToken
    }

    @discardableResult
    func refresh() async throws -> Credentials {
        if let t = refreshTask { return try await t.value }
        guard let c = credentials, !c.refreshToken.isEmpty else {
            throw AIError.unavailable(tr("ChatGPT 登录已过期，请重新登录。", "ChatGPT sign-in expired. Please sign in again."))
        }
        let t = Task { () -> Credentials in
            try await exchange(form: [
                "grant_type": "refresh_token",
                "client_id": c.clientId,
                "refresh_token": c.refreshToken,
                "resource": Self.resource,
            ], clientId: c.clientId, previous: c)
        }
        refreshTask = t
        defer { refreshTask = nil }
        let fresh = try await t.value
        store(fresh)
        return fresh
    }

    // MARK: 模型与调用

    func loadModels() async {
        guard let token = try? await validToken() else { return }
        var req = URLRequest(url: URL(string: Self.resource + "/models")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) else { return }
        var out: [Model] = []
        for m in list {
            if let v = m["visibility"] as? String, v != "list" { continue }
            guard let slug = (m["slug"] as? String) ?? (m["id"] as? String) else { continue }
            let name = (m["display_name"] as? String) ?? (m["title"] as? String) ?? slug
            out.append(Model(id: slug, name: name))
        }
        models = out
    }

    /// 生成文字：Responses API，流式读取。
    func complete(system: String, user: String, model: String?) async throws -> String {
        if models.isEmpty { await loadModels() }
        guard let modelId = (model?.isEmpty == false ? model : nil) ?? models.first?.id else {
            throw AIError.unavailable(tr("没有取到可用的 ChatGPT 模型，请在 AI 设置里刷新模型列表。", "No ChatGPT models are available. Refresh the model list in AI settings."))
        }
        do {
            return try await stream(system: system, user: user, model: modelId, token: try await validToken())
        } catch AIError.http(401, _) {
            let c = try await refresh()
            return try await stream(system: system, user: user, model: modelId, token: c.accessToken)
        }
    }

    private func stream(system: String, user: String, model: String, token: String) async throws -> String {
        var req = URLRequest(url: URL(string: Self.resource + "/responses")!, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "model": model,
            "instructions": system,
            "input": [["role": "user", "content": user]],
            "store": false,
            "stream": true,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            var raw = Data()
            for try await b in bytes { raw.append(b); if raw.count > 4000 { break } }
            let json = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: raw.prefix(400), as: UTF8.self)
            throw AIError.http(code, msg)
        }
        var text = ""
        var finished = false
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let d = payload.data(using: .utf8),
                  let ev = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            let type = ev["type"] as? String ?? ""
            switch type {
            case "response.output_text.delta":
                text += ev["delta"] as? String ?? ""
            case "response.output_text.done":
                if text.isEmpty { text = ev["text"] as? String ?? "" }
            case "response.completed":
                finished = true
            case "response.failed", "response.incomplete", "error":
                let r = ev["response"] as? [String: Any]
                let err = (r?["error"] as? [String: Any]) ?? (ev["error"] as? [String: Any]) ?? ev
                let codeStr = err["code"] as? String ?? ""
                if codeStr.contains("usage_limit") {
                    throw AIError.unavailable(tr("ChatGPT 订阅的用量已达上限，请稍后再试。", "Your ChatGPT plan's usage limit was reached. Try again later."))
                }
                if type == "response.incomplete", !text.isEmpty { finished = true; break }
                throw AIError.unavailable((err["message"] as? String) ?? tr("ChatGPT 没有完成回答。", "ChatGPT didn't finish the response."))
            default:
                break
            }
            if finished { break }
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

    static func email(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64),
              let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return json["email"] as? String
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
                        Text(tr("已登录", "Signed in")).font(RT.font(15, .bold))
                        Text(c.email ?? tr("ChatGPT 账号", "ChatGPT account")).font(RT.font(13)).foregroundColor(IOS3.value).lineLimit(1)
                    } else {
                        Text(tr("未登录", "Not signed in")).font(RT.font(15, .bold))
                        Text(tr("需要 ChatGPT Plus / Pro 等付费订阅", "Requires a paid ChatGPT plan")).font(RT.font(12)).foregroundColor(IOS3.secondary)
                    }
                }
                Spacer()
                if auth.signingIn {
                    ProgressView()
                } else if auth.isSignedIn {
                    Button(tr("退出", "Sign Out")) { auth.signOut() }
                        .buttonStyle(RetroButtonStyle(compact: true, destructive: true))
                } else {
                    Button(tr("用 ChatGPT 登录", "Sign in with ChatGPT")) { auth.signIn() }
                        .buttonStyle(RetroButtonStyle(isDefault: true, compact: true))
                }
            }
            .padding(12)

            if auth.signingIn && !auth.isSignedIn {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("在弹出的页面里登录 ChatGPT 并同意授权。完成后会自动回来；如果停在一个打不开的 127.0.0.1 页面，复制浏览器地址栏里的网址粘贴到这里：",
                            "Sign in to ChatGPT in the page that opens and approve. It returns automatically; if it stops on a 127.0.0.1 page that won't load, copy that address and paste it here:"))
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

            Text(tr("这是 OpenAI 官方提供给开源 / 本地应用的“用 ChatGPT 登录”方式：令牌只存在这台手机的钥匙串里，请求直接从手机发给 OpenAI，用的是你订阅里的额度（不另外收费，但会占用订阅的使用上限）。随时可以在这里退出，或在 ChatGPT 设置里断开 RetroMail。",
                    "This is OpenAI's official Sign in with ChatGPT for open-source / local apps. Tokens stay in this iPhone's Keychain, requests go straight from the phone to OpenAI, and usage counts against your plan's limits (no extra charge). Sign out here any time, or disconnect RetroMail in ChatGPT settings."))
                .font(RT.font(11))
                .opacity(0.75)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }
}
