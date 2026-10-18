import SwiftUI

enum Route: Hashable {
    case folder(MailAccount, MailFolder)
    case account(MailAccount?)
    case settings
}

struct DesktopView: View {
    @ObservedObject private var store = AccountStore.shared
    @ObservedObject private var center = MailCenter.shared
    @EnvironmentObject private var settings: AppSettings
    @State private var path = NavigationPath()
    @State private var compose: ComposeRequest?
    @State private var showAbout = false

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                menuBar
                ZStack(alignment: .bottom) {
                    SpringWallpaper()
                    if store.accounts.isEmpty {
                        welcome
                    } else {
                        springboard
                    }
                    dock
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
            }
            .background(Color.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .folder(let a, let f):
                    MessageListView(account: a, folder: f)
                case .account(let a):
                    AccountEditView(existing: a)
                case .settings:
                    SettingsView()
                }
            }
        }
        .fullScreenCover(item: $compose) { req in
            ComposeView(request: req)
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
        }
        .overlay {
            if showAbout { AboutBox { showAbout = false } }
        }
        .task {
            await center.loadAll()
        }
    }

    // MARK: 菜单栏

    private var menuBar: some View {
        RetroMenuBar {
            Menu {
                Button(tr("新邮件", "New Message")) { compose = ComposeRequest() }
                    .disabled(store.accounts.isEmpty)
                Button(tr("全部刷新", "Refresh All")) { Task { await center.loadAll() } }
            } label: {
                Text(tr("文件", "File"))
            }
            Menu {
                ForEach(store.accounts) { a in
                    if let inbox = center.folder(a, role: .inbox) {
                        Button("\(a.email) · \(tr("收件箱", "Inbox"))") { path.append(Route.folder(a, inbox)) }
                    }
                }
                if store.accounts.isEmpty {
                    Text(tr("尚无账户", "No accounts"))
                }
            } label: {
                Text(tr("邮箱", "Mail"))
            }
            Menu {
                Picker(tr("外观", "Appearance"), selection: $settings.appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                Picker(tr("语言", "Language"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }
                Divider()
                Button(tr("控制面板…", "Control Panel…")) { path.append(Route.settings) }
                Button(tr("添加账户…", "Add Account…")) { path.append(Route.account(nil)) }
                Button(tr("关于 RetroMail…", "About RetroMail…")) { showAbout = true }
            } label: {
                Text(tr("特别", "Special"))
            }
        }
    }

    // MARK: 首次使用

    private var welcome: some View {
        VStack {
            RetroWindow(title: tr("欢迎使用 RetroMail", "Welcome to RetroMail"), fill: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        GlossyIcon(symbol: "envelope.fill", colors: .blue, size: 52)
                        Text(tr("还没有邮箱账户。\n\n添加一个 IMAP/SMTP 账户即可开始收发邮件。企业邮箱需要在管理后台开启 IMAP 服务。",
                                "No mail accounts yet.\n\nAdd an IMAP/SMTP account to start. Company mailboxes may need IMAP enabled by your administrator."))
                            .font(RT.font(13))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        Button(tr("添加账户…", "Add Account…")) { path.append(Route.account(nil)) }
                            .buttonStyle(RetroButtonStyle(isDefault: true))
                    }
                }
                .padding(16)
                .foregroundColor(.ink)
            }
            .padding(20)
            .padding(.top, 20)
            Spacer()
        }
    }

    // MARK: 桌面（图标网格）

    private let columns = [GridItem(.adaptive(minimum: 78, maximum: 110), spacing: 10, alignment: .top)]

    private var springboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(store.accounts) { a in
                    VStack(alignment: .leading, spacing: 14) {
                        accountLabel(a)
                        accountIcons(a)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 130)
        }
        .refreshable { await center.loadAll() }
    }

    private func accountLabel(_ a: MailAccount) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.square.fill")
            Text(a.name.isEmpty ? a.email : "\(a.name) · \(a.email)")
                .lineLimit(1)
            if center.loadingAccounts.contains(a.id) {
                Image(systemName: "hourglass")
            }
        }
        .font(RT.font(12, .bold))
        .foregroundColor(.paper)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.ink)
        .background(Rectangle().fill(Color.ink.opacity(0.4)).offset(x: 2, y: 2))
    }

    @ViewBuilder
    private func accountIcons(_ a: MailAccount) -> some View {
        if let err = center.folderErrors[a.id], center.folders[a.id] == nil {
            RetroWindow(title: tr("无法连接", "Can't Connect"), fill: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("⚠ \(err)")
                        .font(RT.font(12))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button(tr("重试", "Retry")) { Task { await center.loadFolders(a) } }
                            .buttonStyle(RetroButtonStyle(compact: true))
                        Button(tr("账户设置", "Account Settings")) { path.append(Route.account(a)) }
                            .buttonStyle(RetroButtonStyle(compact: true))
                    }
                }
                .padding(12)
                .foregroundColor(.ink)
            }
        } else if let folders = center.folders[a.id] {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(folders.filter(\.selectable)) { f in
                    SpringButton(symbol: f.role.springSymbol,
                                 label: f.displayName,
                                 colors: f.iconColors,
                                 size: 60,
                                 badge: center.unread[center.unreadKey(a.id, f.path)] ?? 0,
                                 plate: true,
                                 labelWidth: 84) {
                        path.append(Route.folder(a, f))
                    }
                }
            }
        } else {
            RetroBusy(text: tr("正在连接服务器…", "Connecting…"))
                .padding(8)
                .background(Color.paper)
                .overlay(Rectangle().stroke(Color.ink, lineWidth: 1))
        }
    }

    // MARK: Dock

    private var dock: some View {
        SpringDock {
            Group {
                if store.accounts.isEmpty {
                    SpringButton(symbol: "person.crop.circle.badge.plus", label: tr("添加账户", "Add Account"),
                                 colors: .blue, size: 54) { path.append(Route.account(nil)) }
                } else {
                    SpringButton(symbol: "square.and.pencil", label: tr("新邮件", "Compose"),
                                 colors: .blue, size: 54) { compose = ComposeRequest() }
                    SpringButton(symbol: "arrow.clockwise", label: tr("全部刷新", "Refresh"),
                                 colors: .green, size: 54) { Task { await center.loadAll() } }
                }
                SpringButton(symbol: "gearshape.fill", label: tr("控制面板", "Settings"),
                             colors: .graphite, size: 54) { path.append(Route.settings) }
                SpringButton(symbol: "info", label: tr("关于", "About"),
                             colors: .purple, size: 54) { showAbout = true }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct AboutBox: View {
    let onClose: () -> Void

    var body: some View {
        RetroDialog {
            VStack(spacing: 12) {
                Image(systemName: "envelope")
                    .font(.system(size: 40))
                Text("RetroMail").font(RT.font(22, .bold))
                Text(tr("版本 2.1", "Version 2.1")).font(RT.font(12))
                RetroDivider()
                Text(tr("一个黑白的、老派的邮件客户端。\nIMAP · SMTP · 会话 · 富文本 · AI",
                        "A black-and-white, old-school mail client.\nIMAP · SMTP · Threads · Rich text · AI"))
                    .font(RT.font(12))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(tr("好", "OK")) { onClose() }
                    .buttonStyle(RetroButtonStyle(isDefault: true))
            }
            .foregroundColor(.ink)
        }
    }
}
