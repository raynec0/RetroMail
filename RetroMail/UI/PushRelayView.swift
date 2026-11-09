import SwiftUI
import UIKit

/// 推送中继设置：让 RetroMail 关闭时也能秒收新邮件通知。
///
/// 自签应用用不了苹果推送服务（APNs），iOS 也不允许普通应用在后台一直联网，
/// 所以真正的“锁屏秒到”只能由一台常开的机器（VPS / NAS / 软路由 / 电脑）盯着邮箱，
/// 再通过 Bark（或 ntfy）这类有苹果推送资格的通知 App 推到手机。点通知会直接在 RetroMail 里打开那封邮件。
struct PushRelayView: View {
    @AppStorage(MailPrefs.relayKey) private var relayOn = false
    @AppStorage("relay.barkServer") private var barkServer = "https://api.day.app"
    @AppStorage("relay.barkKey") private var barkKey = ""
    @AppStorage("relay.preview") private var preview = true
    @AppStorage("relay.token") private var token = ""
    @AppStorage("relay.workerURL") private var workerURL = ""
    @State private var includePasswords = false
    @State private var busy = false
    @State private var message: String?
    @ObservedObject private var store = AccountStore.shared

    var body: some View {
        RetroScreen(title: tr("即时推送", "Instant Push"), back: tr("设置", "Settings")) {
            EmptyView()
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    explanation
                    RetroGroup(tr("第 1 步：在手机上装 Bark", "Step 1: Install Bark")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tr("在 App Store 安装免费的“Bark”，打开后复制它给你的推送地址里 https://api.day.app/ 后面那串 Key，粘贴到下面。",
                                    "Install the free “Bark” app from the App Store, copy the key after https://api.day.app/ in its push URL, and paste it below."))
                                .font(RT.font(12))
                                .fixedSize(horizontal: false, vertical: true)
                            Button(tr("打开 App Store 搜索 Bark", "Find Bark on the App Store")) {
                                if let u = URL(string: "itms-apps://search.itunes.apple.com/WebObjects/MZSearch.woa/wa/search?media=software&term=Bark") {
                                    UIApplication.shared.open(u)
                                }
                            }
                            .buttonStyle(RetroButtonStyle(compact: true))
                        }
                        .padding(12)
                        RetroField(label: tr("服务器", "Server"), text: $barkServer, placeholder: "https://api.day.app", keyboard: .URL)
                        RetroField(label: "Key", text: $barkKey, placeholder: tr("Bark 里的 Key", "Key from Bark"))
                        HStack {
                            Button(tr("发一条测试通知", "Send Test Push")) { test() }
                                .buttonStyle(RetroButtonStyle(isDefault: true, compact: true))
                                .disabled(barkKey.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                            Spacer()
                        }
                        .padding(12)
                    }

                    RetroGroup(tr("第 2 步（推荐）：部署到 Cloudflare，免费、不用服务器", "Step 2 (recommended): Deploy to Cloudflare — free, no server")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tr("""
                            仓库 cloudflare 文件夹里的 worker.js 是一个 Cloudflare Worker，两种方式同时工作、同一封邮件只推一次：
                            • 每分钟登录邮箱检查一次（最多约 1 分钟延迟，不用改邮箱设置）；
                            • 公司邮箱“自动转发一份副本”到你 Cloudflare 域名上的地址（如 push@你的域名），收到就推送（几秒内）。
                            部署步骤见 cloudflare/README.md：新建 Worker → 粘贴 worker.js → 绑定 KV（名称 STATE）→ 添加机密变量 CONFIG（内容就是下面拷贝的配置）→ 添加 Cron 触发器 * * * * * → Email Routing 里把 push@你的域名 发送到这个 Worker。
                            """, """
                            worker.js in the repo's cloudflare folder is a Cloudflare Worker. Both methods run together and each message is pushed once:
                            • checks the mailbox every minute (≤ 1 min delay, no mailbox changes);
                            • your work mailbox auto-forwards a copy to an address on your Cloudflare domain (e.g. push@yourdomain), pushed within seconds.
                            See cloudflare/README.md: create a Worker → paste worker.js → bind KV as STATE → add secret CONFIG (the config copied below) → add Cron * * * * * → in Email Routing send push@yourdomain to this Worker.
                            """))
                                .font(RT.font(12))
                                .fixedSize(horizontal: false, vertical: true)
                            RetroField(label: tr("Worker 地址", "Worker URL"), text: $workerURL, placeholder: "https://retromail-push.xxx.workers.dev", keyboard: .URL)
                            HStack(spacing: 8) {
                                Button(tr("拷贝 CONFIG", "Copy CONFIG")) {
                                    includePasswords = true   // Cloudflare 要登录邮箱，必须带密码
                                    UIPasteboard.general.string = configJSON()
                                    message = tr("已拷贝。到 Cloudflare → 你的 Worker → 设置 → 变量和机密 → 添加“机密”，名称填 CONFIG，值粘贴进去。",
                                                 "Copied. In Cloudflare → your Worker → Settings → Variables and Secrets, add a Secret named CONFIG and paste it.")
                                }
                                .buttonStyle(RetroButtonStyle(compact: true))
                                Button(tr("让 Worker 发测试通知", "Test via Worker")) { testWorker(path: "test") }
                                    .buttonStyle(RetroButtonStyle(compact: true))
                                    .disabled(workerURL.isEmpty || busy)
                                Button(tr("立即检查", "Check Now")) { testWorker(path: "run") }
                                    .buttonStyle(RetroButtonStyle(compact: true))
                                    .disabled(workerURL.isEmpty || busy)
                            }
                        }
                        .padding(12)
                    }

                    RetroGroup(tr("第 2 步（另一种）：在常开的机器上运行中继", "Step 2 (alternative): Run the relay on an always-on machine")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tr("仓库里的 relay 文件夹是中继程序（只用 Python 标准库，也可以用 Docker）。点下面生成配置文件 config.json，放到 relay 文件夹里，然后运行：",
                                    "The relay folder in the repo contains the relay (pure Python, or Docker). Generate config.json below, put it in the relay folder, then run:"))
                                .font(RT.font(12))
                                .fixedSize(horizontal: false, vertical: true)
                            Text("python3 retromail_push.py --test\npython3 retromail_push.py")
                                .font(.system(size: 13, design: .monospaced))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.85)))
                                .foregroundColor(HexColor.color("#9BE58B"))
                                .textSelection(.enabled)
                            RetroCheckbox(label: tr("通知里显示正文预览", "Show a preview in the push"), isOn: $preview)
                            RetroCheckbox(label: tr("把邮箱密码写进配置（否则需要自己填）", "Include mailbox passwords (otherwise fill them in yourself)"), isOn: $includePasswords)
                            HStack(spacing: 8) {
                                Button(tr("拷贝配置", "Copy Config")) {
                                    UIPasteboard.general.string = configJSON()
                                    message = tr("已拷贝 config.json 的内容。", "config.json copied.")
                                }
                                .buttonStyle(RetroButtonStyle(compact: true))
                                Button(tr("共享配置文件…", "Share Config File…")) { shareConfig() }
                                    .buttonStyle(RetroButtonStyle(compact: true))
                            }
                        }
                        .padding(12)
                    }

                    RetroGroup(tr("第 3 步：打开中继模式", "Step 3: Turn on relay mode")) {
                        RetroCheckbox(label: tr("我已经在用推送中继（RetroMail 不再自己弹通知，避免重复）", "I'm using the relay (RetroMail won't post its own alerts, to avoid duplicates)"), isOn: $relayOn)
                        Text(tr("打开后，“后台保持在线”可以关掉，最省电。点 Bark 的通知会直接在 RetroMail 里打开那封邮件。",
                                "With this on you can turn off “Stay online in background” to save battery. Tapping a Bark notification opens the message in RetroMail."))
                            .font(RT.font(11))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }
        }
        .busyOverlay(busy, tr("正在发送…", "Sending…"))
        .retroAlert($message)
    }

    private var explanation: some View {
        Text(tr("""
        为什么需要这个：iOS 只给有苹果推送资格（付费开发者账号签名）的 App 发锁屏推送，也不允许普通 App 在后台一直联网。自签安装的 RetroMail 两样都没有，所以关掉以后只能等 iOS 偶尔唤醒它（15 分钟到几小时不等，甚至不唤醒）。
        解决办法和 Gmail、Spark 一样：由服务器盯着邮箱、有新邮件就推送。这里用你自己的机器做“服务器”，用 Bark 做推送通道，邮件密码只存在你自己的机器上。
        """, """
        Why: iOS only delivers lock-screen pushes for apps signed with a paid developer account, and doesn't let ordinary apps stay connected in the background. A self-signed RetroMail has neither, so when it's closed iOS only wakes it occasionally (15 min to hours, or never).
        The fix is what Gmail and Spark do: a server watches the mailbox and pushes new mail. Here your own machine is the server and Bark is the push channel; your mail password stays on your machine.
        """))
        .font(RT.font(12))
        .foregroundColor(IOS3.groupHeader)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    private func configJSON() -> String {
        var accounts: [[String: Any]] = []
        for a in store.accounts {
            let cfg = a.imapConfig()
            var d: [String: Any] = [
                "name": a.name.isEmpty ? a.email : a.name,
                "email": a.email,
                "host": cfg.host,
                "port": cfg.port,
                "ssl": cfg.security == .ssl,
                "starttls": cfg.security == .starttls,
                "username": cfg.username,
                "password": includePasswords ? cfg.password : tr("在这里填邮箱密码", "your-mailbox-password"),
                "folder": MailCenter.shared.folder(a, role: .inbox)?.path ?? "INBOX",
            ]
            if a.allowInsecureTLS { d["allow_insecure"] = true }
            accounts.append(d)
        }
        if token.isEmpty { token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
        let root: [String: Any] = [
            "token": token,
            "push": ["type": "bark", "server": barkServer.trimmingCharacters(in: .whitespaces),
                     "key": barkKey.trimmingCharacters(in: .whitespaces), "group": "RetroMail", "level": "timeSensitive"],
            "preview": preview,
            "idle_seconds": 600,
            "accounts": accounts,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func testWorker(path: String) {
        if token.isEmpty { _ = configJSON() }
        let base = workerURL.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/" + path + "?token=" + token) else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                var req = URLRequest(url: url, timeoutInterval: 60)
                req.httpMethod = "GET"
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let text = String(decoding: data.prefix(400), as: UTF8.self)
                if text.contains("is running") {
                    message = tr("Worker 在运行，但口令不对：请重新“拷贝 CONFIG”并更新 Cloudflare 里的 CONFIG 机密。", "The Worker is running but the token doesn't match. Copy CONFIG again and update the secret in Cloudflare.")
                } else {
                    message = tr("Worker 返回（\(code)）：", "Worker replied (\(code)): ") + text
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func shareConfig() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("config.json")
        try? configJSON().write(to: url, atomically: true, encoding: .utf8)
        FilesPresenter.share(url) { _ in }
    }

    private func test() {
        busy = true
        let server = barkServer.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let body: [String: Any] = [
            "device_key": barkKey.trimmingCharacters(in: .whitespaces),
            "title": "RetroMail",
            "subtitle": tr("推送测试", "Push test"),
            "body": tr("能看到这条通知说明 Bark 设置正确。点一下会打开 RetroMail。", "If you see this, Bark is set up. Tap to open RetroMail."),
            "group": "RetroMail",
            "url": "retromail://open",
        ]
        Task {
            defer { busy = false }
            guard let url = URL(string: (server.isEmpty ? "https://api.day.app" : server) + "/push") else { return }
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                message = code == 200
                    ? tr("已发送，锁屏应该马上收到一条 Bark 通知。", "Sent — a Bark notification should arrive now.")
                    : tr("Bark 返回错误（\(code)）：", "Bark returned \(code): ") + String(decoding: data.prefix(200), as: UTF8.self)
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
