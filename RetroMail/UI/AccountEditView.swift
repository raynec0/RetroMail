import SwiftUI

struct ServerPreset: Identifiable {
    let name: String
    let imap: String
    let smtp: String
    var id: String { name }

    static var all: [ServerPreset] {
        [
            ServerPreset(name: tr("腾讯企业邮", "Tencent Exmail"), imap: "imap.exmail.qq.com", smtp: "smtp.exmail.qq.com"),
            ServerPreset(name: tr("阿里企业邮", "Alibaba Mail"), imap: "imap.qiye.aliyun.com", smtp: "smtp.qiye.aliyun.com"),
            ServerPreset(name: tr("网易企业邮", "NetEase Enterprise"), imap: "imap.qiye.163.com", smtp: "smtp.qiye.163.com"),
            ServerPreset(name: tr("QQ 邮箱", "QQ Mail"), imap: "imap.qq.com", smtp: "smtp.qq.com"),
            ServerPreset(name: tr("163 邮箱", "163 Mail"), imap: "imap.163.com", smtp: "smtp.163.com"),
            ServerPreset(name: "Gmail", imap: "imap.gmail.com", smtp: "smtp.gmail.com"),
        ]
    }
}

private var securityOptions: [(MailSecurity, String)] {
    MailSecurity.allCases.map { ($0, $0.label) }
}

struct AccountEditView: View {
    let existing: MailAccount?
    @State private var a: MailAccount
    @State private var imapPass: String
    @State private var smtpPass: String
    @State private var message: String?
    @State private var testing = false
    @State private var confirmDelete = false
    @State private var lastEmail: String
    @Environment(\.dismiss) private var dismiss

    init(existing: MailAccount?) {
        self.existing = existing
        let acc = existing ?? MailAccount()
        _a = State(initialValue: acc)
        _imapPass = State(initialValue: existing.flatMap { Keychain.get($0.imapKey) } ?? "")
        _smtpPass = State(initialValue: existing.flatMap { Keychain.get($0.smtpKey) } ?? "")
        _lastEmail = State(initialValue: acc.email)
    }

    var body: some View {
        RetroScreen(title: existing == nil ? tr("新建账户", "New Account") : (existing!.name.isEmpty ? existing!.email : existing!.name)) {
            Button(tr("存储", "Save")) { save() }
                .buttonStyle(BarButtonStyle(kind: .done))
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    identityGroup
                    imapGroup
                    smtpGroup
                    optionsGroup
                    actions
                }
                .padding(14)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .busyOverlay(testing, tr("正在测试连接…", "Testing connection…"))
        .retroAlert($message)
        .ios3ActionSheet(isPresented: $confirmDelete,
                         title: tr("删除这个账户后，本机上的缓存也会一并清除，服务器上的邮件不受影响。",
                                   "Deleting this account removes its local cache. Mail on the server is not affected."),
                         actions: [SheetAction(tr("删除账户", "Delete Account"), role: .destructive) { deleteAccount() }])
        .onChange(of: a.email) { newValue in autofill(newValue) }
        .onChange(of: a.imapSecurity) { s in
            a.imapPort = s == .ssl ? 993 : 143
        }
        .onChange(of: a.smtpSecurity) { s in
            switch s {
            case .ssl: a.smtpPort = 465
            case .starttls: a.smtpPort = 587
            case .none: a.smtpPort = 25
            }
        }
    }

    private var identityGroup: some View {
        RetroGroup(tr("身份", "Identity")) {
            RetroField(label: tr("显示名称", "Name"), text: $a.name, placeholder: tr("如：张三", "e.g. Jane Smith"))
            RetroField(label: tr("邮箱地址", "Email"), text: $a.email, placeholder: "name@company.com", keyboard: .emailAddress)
            HStack(alignment: .top, spacing: 6) {
                Text(tr("签名", "Signature")).font(RT.font(15, .bold)).frame(width: 92, alignment: .leading).padding(.top, 8)
                TextEditor(text: $a.signature)
                    .font(RT.font(15))
                    .foregroundColor(IOS3.value)
                    .scrollContentBackground(.hidden)
                    .frame(height: 70)
            }
        }
    }

    private var imapGroup: some View {
        RetroGroup(tr("收件服务器（IMAP）", "Incoming (IMAP)")) {
            HStack {
                Spacer().frame(width: 86)
                Menu {
                    ForEach(ServerPreset.all) { p in
                        Button(p.name) { apply(p) }
                    }
                } label: {
                    Text(tr("套用常见服务器 ▾", "Use a preset ▾")).font(RT.font(12, .bold))
                }
            }
            RetroField(label: tr("服务器", "Server"), text: $a.imapHost, placeholder: "imap.company.com", keyboard: .URL)
            RetroField(label: tr("端口", "Port"), text: intBinding(\.imapPort), keyboard: .numberPad)
            RetroRadio(label: tr("加密", "Security"), options: securityOptions, selection: $a.imapSecurity)
            RetroField(label: tr("用户名", "Username"), text: $a.imapUser, placeholder: tr("通常就是邮箱地址", "Usually your email"), keyboard: .emailAddress)
            RetroField(label: tr("密码", "Password"), text: $imapPass, placeholder: tr("密码或授权码", "Password or app password"), secure: true)
        }
    }

    private var smtpGroup: some View {
        RetroGroup(tr("发件服务器（SMTP）", "Outgoing (SMTP)")) {
            RetroField(label: tr("服务器", "Server"), text: $a.smtpHost, placeholder: "smtp.company.com", keyboard: .URL)
            RetroField(label: tr("端口", "Port"), text: intBinding(\.smtpPort), keyboard: .numberPad)
            RetroRadio(label: tr("加密", "Security"), options: securityOptions, selection: $a.smtpSecurity)
            RetroCheckbox(label: tr("使用与收件服务器相同的用户名和密码", "Use the same username and password as incoming"), isOn: $a.smtpSameAuth)
            if !a.smtpSameAuth {
                RetroField(label: tr("用户名", "Username"), text: $a.smtpUser, keyboard: .emailAddress)
                RetroField(label: tr("密码", "Password"), text: $smtpPass, secure: true)
            }
        }
    }

    private var optionsGroup: some View {
        RetroGroup(tr("选项", "Options")) {
            RetroCheckbox(label: tr("发送后在“已发送”中保存副本（服务器会自动保存的请关闭，以免重复）",
                                    "Save a copy to Sent after sending (turn off if your server does this itself)"), isOn: $a.saveToSent)
            RetroCheckbox(label: tr("允许不受信任的证书（公司内网自签名证书时使用）",
                                    "Allow untrusted certificates (for self-signed company servers)"), isOn: $a.allowInsecureTLS)
        }
    }

    private var actions: some View {
        VStack(spacing: 14) {
            Text(tr("提示：企业邮箱需由管理员开启 IMAP/SMTP；开启了安全登录的邮箱请使用客户端专用密码。",
                    "Tip: company mailboxes may need IMAP/SMTP enabled by an admin; accounts with 2-step sign-in need an app password."))
                .font(RT.font(14))
                .foregroundColor(IOS3.groupHeader)
                .shadow(color: IOS3.groupHeaderShadow, radius: 0, x: 0, y: 1)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { test() } label: {
                Text(tr("测试连接", "Test Connection")).frame(maxWidth: .infinity)
            }
            .buttonStyle(RetroButtonStyle())
            Button { save() } label: {
                Text(tr("存储", "Save")).frame(maxWidth: .infinity)
            }
            .buttonStyle(RetroButtonStyle(isDefault: true))
            if existing != nil {
                Button { confirmDelete = true } label: {
                    Text(tr("删除账户", "Delete Account")).frame(maxWidth: .infinity)
                }
                .buttonStyle(RetroButtonStyle(destructive: true))
                .padding(.top, 10)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    private func intBinding(_ kp: WritableKeyPath<MailAccount, Int>) -> Binding<String> {
        Binding(
            get: { a[keyPath: kp] == 0 ? "" : String(a[keyPath: kp]) },
            set: { a[keyPath: kp] = Int($0.filter(\.isNumber)) ?? 0 }
        )
    }

    private func domain(of email: String) -> String? {
        let parts = email.split(separator: "@")
        guard parts.count == 2, parts[1].contains(".") else { return nil }
        return String(parts[1]).lowercased()
    }

    private func autofill(_ email: String) {
        let oldDomain = domain(of: lastEmail)
        if let d = domain(of: email) {
            if a.imapHost.isEmpty || (oldDomain != nil && a.imapHost == "imap.\(oldDomain!)") {
                a.imapHost = "imap.\(d)"
            }
            if a.smtpHost.isEmpty || (oldDomain != nil && a.smtpHost == "smtp.\(oldDomain!)") {
                a.smtpHost = "smtp.\(d)"
            }
        }
        if a.imapUser.isEmpty || a.imapUser == lastEmail {
            a.imapUser = email
        }
        lastEmail = email
    }

    private func apply(_ p: ServerPreset) {
        a.imapHost = p.imap
        a.imapSecurity = .ssl
        a.imapPort = 993
        a.smtpHost = p.smtp
        a.smtpSecurity = .ssl
        a.smtpPort = 465
    }

    private func validate() -> String? {
        if !a.email.contains("@") { return tr("请填写正确的邮箱地址。", "Enter a valid email address.") }
        if a.imapHost.trimmingCharacters(in: .whitespaces).isEmpty { return tr("请填写收件服务器地址。", "Enter the incoming server.") }
        if a.smtpHost.trimmingCharacters(in: .whitespaces).isEmpty { return tr("请填写发件服务器地址。", "Enter the outgoing server.") }
        if a.imapPort <= 0 || a.smtpPort <= 0 { return tr("端口号不正确。", "Invalid port.") }
        if imapPass.isEmpty { return tr("请填写密码。", "Enter the password.") }
        return nil
    }

    private func test() {
        if let v = validate() {
            message = v
            return
        }
        testing = true
        let acc = a
        let ip = imapPass
        let sp = smtpPass
        Task {
            var lines: [String] = []
            let conn = IMAPConnection(config: acc.imapConfig(password: ip))
            do {
                try await conn.connect()
                let folders = try await conn.listFolders()
                lines.append(tr("✓ 收件服务器正常（\(folders.count) 个文件夹）", "✓ Incoming OK (\(folders.count) folders)"))
                await conn.logout()
            } catch {
                conn.close()
                lines.append(tr("✗ 收件服务器：", "✗ Incoming: ") + error.localizedDescription)
            }
            do {
                try await SMTPClient(config: acc.smtpConfig(imapPassword: ip, smtpPassword: sp)).verify()
                lines.append(tr("✓ 发件服务器正常", "✓ Outgoing OK"))
            } catch {
                lines.append(tr("✗ 发件服务器：", "✗ Outgoing: ") + error.localizedDescription)
            }
            testing = false
            message = lines.joined(separator: "\n\n")
        }
    }

    private func save() {
        if let v = validate() {
            message = v
            return
        }
        if a.imapUser.isEmpty { a.imapUser = a.email }
        a.email = a.email.trimmingCharacters(in: .whitespaces)
        let acc = a
        AccountStore.shared.save(acc, imapPassword: imapPass, smtpPassword: smtpPass)
        MailCenter.shared.reset(acc.id)
        Task { await MailCenter.shared.loadFolders(acc) }
        dismiss()
    }

    private func deleteAccount() {
        guard let e = existing else { return }
        MailCenter.shared.reset(e.id)
        AccountStore.shared.delete(e)
        dismiss()
    }
}

struct SettingsView: View {
    @ObservedObject private var store = AccountStore.shared
    @EnvironmentObject private var settings: AppSettings
    @AppStorage(BackgroundRefresh.enabledKey) private var notify = false
    @State private var message: String?
    @State private var cacheSize = "…"
    @State private var showAI = false
    @State private var aiConfigured = AIConfig.isConfigured

    var body: some View {
        RetroScreen(title: tr("设置", "Settings"), back: tr("邮箱", "Mailboxes")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    RetroGroup(tr("外观与语言", "Appearance & Language")) {
                        RetroRadio(label: tr("外观", "Theme"), options: Appearance.allCases.map { ($0, $0.label) },
                                   selection: $settings.appearance, labelWidth: 56)
                        RetroRadio(label: tr("语言", "Language"), options: AppLanguage.allCases.map { ($0, $0.label) },
                                   selection: $settings.language, labelWidth: 56)
                    }

                    RetroGroup(tr("阅读", "Reading")) {
                        RetroCheckbox(label: tr("按会话分组（同一主题的往来邮件合并显示，包括“已发送”中的回复）",
                                                "Group by conversation (includes your replies from Sent)"), isOn: $settings.threaded)
                        RetroCheckbox(label: tr("默认折叠引用的历史内容", "Collapse quoted history by default"), isOn: $settings.hideQuotes)
                    }

                    RetroGroup(tr("账户", "Accounts")) {
                        ForEach(store.accounts) { a in
                            NavigationLink(value: Route.account(a)) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(a.name.isEmpty ? a.email : a.name).font(RT.font(16, .bold))
                                        Text("\(a.email) · \(a.imapHost)").font(RT.font(13)).foregroundColor(IOS3.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Chevron()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        NavigationLink(value: Route.account(nil)) {
                            HStack {
                                Text(tr("添加账户…", "Add Account…")).font(RT.font(16, .bold)).foregroundColor(IOS3.value)
                                Spacer()
                                Chevron()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    RetroGroup(tr("AI 助手", "AI Assistant")) {
                        HStack {
                            Text(aiConfigured ? tr("✓ 已设置：", "✓ Configured: ") + AIConfig.load().model : tr("未设置", "Not set up"))
                                .font(RT.font(13))
                                .lineLimit(1)
                            Spacer()
                            Button(tr("设置…", "Set Up…")) { showAI = true }
                                .buttonStyle(RetroButtonStyle(compact: true))
                        }
                        Text(tr("用于写信时撰写、润色、翻译，以及总结会话。", "Used to write, polish and translate mail, and to recap threads."))
                            .font(RT.font(11))
                    }

                    RetroGroup(tr("新邮件通知", "New Mail Alerts")) {
                        RetroCheckbox(label: tr("在后台检查收件箱，有新邮件时通知我", "Check the inbox in the background and notify me"), isOn: $notify)
                        Text(tr("检查频率由 iOS 决定（通常 15 分钟到数小时一次）。", "iOS decides how often (usually every 15 min to a few hours)."))
                            .font(RT.font(11))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    RetroGroup(tr("存储", "Storage")) {
                        HStack {
                            Text(tr("离线缓存：", "Offline cache: ") + cacheSize).font(RT.font(13))
                            Spacer()
                            Button(tr("清除", "Clear")) {
                                cacheSize = "…"
                                Task {
                                    cacheSize = await Task.detached { () -> String in
                                        DiskCache.clear()
                                        return DiskCache.sizeDescription
                                    }.value
                                }
                            }
                            .buttonStyle(RetroButtonStyle(compact: true))
                        }
                    }

                    RetroGroup(tr("关于", "About")) {
                        Text(tr("RetroMail 3.2\n标准 IMAP4rev1 / SMTP 客户端。密码保存在系统钥匙串中，邮件只在你的设备与邮件服务器之间传输（使用 AI 功能时，相关内容会发送给你设置的 AI 服务商）。",
                                "RetroMail 3.2\nStandard IMAP4rev1 / SMTP client. Passwords live in the iOS Keychain; mail goes only between your device and your mail server (AI features send the relevant text to the AI provider you configure)."))
                            .font(RT.font(12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .foregroundColor(.ink)
            }
        }
        .retroAlert($message)
        .task { cacheSize = await Task.detached { DiskCache.sizeDescription }.value }
        .sheet(isPresented: $showAI, onDismiss: { aiConfigured = AIConfig.isConfigured }) {
            AISettingsSheet()
                .preferredColorScheme(settings.colorScheme)
        }
        .onChange(of: notify) { on in
            guard on else { return }
            Task {
                let granted = await BackgroundRefresh.requestPermission()
                if granted {
                    BackgroundRefresh.schedule()
                } else {
                    notify = false
                    message = tr("没有通知权限。请到“设置 > 通知 > RetroMail”中允许通知。", "Notifications are off. Allow them in Settings > Notifications > RetroMail.")
                }
            }
        }
    }
}
