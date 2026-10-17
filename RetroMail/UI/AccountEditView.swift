import SwiftUI

struct ServerPreset: Identifiable {
    let name: String
    let imap: String
    let smtp: String
    var id: String { name }

    static let all: [ServerPreset] = [
        ServerPreset(name: "腾讯企业邮", imap: "imap.exmail.qq.com", smtp: "smtp.exmail.qq.com"),
        ServerPreset(name: "阿里企业邮", imap: "imap.qiye.aliyun.com", smtp: "smtp.qiye.aliyun.com"),
        ServerPreset(name: "网易企业邮", imap: "imap.qiye.163.com", smtp: "smtp.qiye.163.com"),
        ServerPreset(name: "QQ 邮箱", imap: "imap.qq.com", smtp: "smtp.qq.com"),
        ServerPreset(name: "163 邮箱", imap: "imap.163.com", smtp: "smtp.163.com"),
        ServerPreset(name: "Gmail", imap: "imap.gmail.com", smtp: "smtp.gmail.com"),
    ]
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
        RetroScreen(title: existing == nil ? "新建账户" : "账户设置") {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    identityGroup
                    imapGroup
                    smtpGroup
                    optionsGroup
                    actions
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .busyOverlay(testing, "正在测试连接…")
        .retroAlert($message)
        .confirmationDialog("删除这个账户？本机上的缓存也会一并清除，服务器上的邮件不受影响。",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除账户", role: .destructive) { deleteAccount() }
            Button("取消", role: .cancel) {}
        }
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

    // MARK: 分组

    private var identityGroup: some View {
        RetroGroup("身份") {
            RetroField(label: "显示名称", text: $a.name, placeholder: "如：张三")
            RetroField(label: "邮箱地址", text: $a.email, placeholder: "name@company.com", keyboard: .emailAddress)
            HStack(alignment: .top, spacing: 6) {
                Text("签名").font(RT.font(13, .bold)).frame(width: 76, alignment: .trailing).padding(.top, 6)
                TextEditor(text: $a.signature)
                    .font(RT.font(13))
                    .scrollContentBackground(.hidden)
                    .frame(height: 64)
                    .padding(2)
                    .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
            }
        }
    }

    private var imapGroup: some View {
        RetroGroup("收件服务器（IMAP）") {
            HStack {
                Spacer().frame(width: 82)
                Menu {
                    ForEach(ServerPreset.all) { p in
                        Button(p.name) { apply(p) }
                    }
                } label: {
                    Text("套用常见服务器 ▾").font(RT.font(12, .bold)).underline()
                }
            }
            RetroField(label: "服务器", text: $a.imapHost, placeholder: "imap.company.com", keyboard: .URL)
            RetroField(label: "端口", text: intBinding(\.imapPort), keyboard: .numberPad)
            RetroRadioRow(label: "加密", selection: $a.imapSecurity)
            RetroField(label: "用户名", text: $a.imapUser, placeholder: "通常就是邮箱地址", keyboard: .emailAddress)
            RetroField(label: "密码", text: $imapPass, placeholder: "密码或授权码", secure: true)
        }
    }

    private var smtpGroup: some View {
        RetroGroup("发件服务器（SMTP）") {
            RetroField(label: "服务器", text: $a.smtpHost, placeholder: "smtp.company.com", keyboard: .URL)
            RetroField(label: "端口", text: intBinding(\.smtpPort), keyboard: .numberPad)
            RetroRadioRow(label: "加密", selection: $a.smtpSecurity)
            RetroCheckbox(label: "使用与收件服务器相同的用户名和密码", isOn: $a.smtpSameAuth)
            if !a.smtpSameAuth {
                RetroField(label: "用户名", text: $a.smtpUser, keyboard: .emailAddress)
                RetroField(label: "密码", text: $smtpPass, secure: true)
            }
        }
    }

    private var optionsGroup: some View {
        RetroGroup("选项") {
            RetroCheckbox(label: "发送后在“已发送”中保存副本（如果服务器会自动保存，请关闭以免重复）", isOn: $a.saveToSent)
            RetroCheckbox(label: "允许不受信任的证书（公司内网自签名证书时使用）", isOn: $a.allowInsecureTLS)
        }
    }

    private var actions: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                if existing != nil {
                    Button("删除") { confirmDelete = true }
                        .buttonStyle(RetroButtonStyle(compact: true))
                }
                Spacer()
                Button("测试连接") { test() }
                    .buttonStyle(RetroButtonStyle())
                Button("存储") { save() }
                    .buttonStyle(RetroButtonStyle(isDefault: true))
            }
            Text("提示：企业邮箱需由管理员开启 IMAP/SMTP；开启了“安全登录”的邮箱请使用客户端专用密码。")
                .font(RT.font(11))
                .foregroundColor(.black)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
    }

    // MARK: 逻辑

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
        if !a.email.contains("@") { return "请填写正确的邮箱地址。" }
        if a.imapHost.trimmingCharacters(in: .whitespaces).isEmpty { return "请填写收件服务器地址。" }
        if a.smtpHost.trimmingCharacters(in: .whitespaces).isEmpty { return "请填写发件服务器地址。" }
        if a.imapPort <= 0 || a.smtpPort <= 0 { return "端口号不正确。" }
        if imapPass.isEmpty { return "请填写密码。" }
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
                lines.append("✓ 收件服务器正常（\(folders.count) 个文件夹）")
                await conn.logout()
            } catch {
                conn.close()
                lines.append("✗ 收件服务器：\(error.localizedDescription)")
            }
            do {
                try await SMTPClient(config: acc.smtpConfig(imapPassword: ip, smtpPassword: sp)).verify()
                lines.append("✓ 发件服务器正常")
            } catch {
                lines.append("✗ 发件服务器：\(error.localizedDescription)")
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
    @AppStorage(BackgroundRefresh.enabledKey) private var notify = false
    @State private var message: String?
    @State private var cacheSize = DiskCache.sizeDescription

    var body: some View {
        RetroScreen(title: "控制面板") {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    RetroGroup("账户") {
                        ForEach(store.accounts) { a in
                            NavigationLink(value: Route.account(a)) {
                                HStack {
                                    Image(systemName: "person.crop.square")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(a.name.isEmpty ? a.email : a.name).font(RT.font(14, .bold))
                                        Text("\(a.email) · \(a.imapHost)").font(RT.font(11)).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                                }
                                .padding(8)
                                .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(InvertOnPressStyle())
                        }
                        NavigationLink(value: Route.account(nil)) {
                            Text("添加账户…")
                        }
                        .buttonStyle(RetroButtonStyle(compact: true))
                    }

                    RetroGroup("新邮件通知") {
                        RetroCheckbox(label: "在后台检查收件箱，有新邮件时通知我", isOn: $notify)
                        Text("检查频率由 iOS 决定（通常每 15 分钟到数小时一次），取决于你使用本应用的频率和电量。")
                            .font(RT.font(11))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    RetroGroup("存储") {
                        HStack {
                            Text("离线缓存：\(cacheSize)").font(RT.font(13))
                            Spacer()
                            Button("清除") {
                                DiskCache.clear()
                                cacheSize = DiskCache.sizeDescription
                            }
                            .buttonStyle(RetroButtonStyle(compact: true))
                        }
                    }

                    RetroGroup("关于") {
                        Text("RetroMail 1.0\n标准 IMAP4rev1 / SMTP 客户端，密码保存在系统钥匙串中，邮件只在你的设备与邮件服务器之间传输。")
                            .font(RT.font(12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .foregroundColor(.black)
            }
        }
        .retroAlert($message)
        .onChange(of: notify) { on in
            guard on else { return }
            Task {
                let granted = await BackgroundRefresh.requestPermission()
                if granted {
                    BackgroundRefresh.schedule()
                } else {
                    notify = false
                    message = "没有通知权限。请到“设置 > 通知 > RetroMail”中允许通知。"
                }
            }
        }
    }
}
