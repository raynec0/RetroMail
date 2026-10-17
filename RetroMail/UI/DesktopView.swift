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
                if store.accounts.isEmpty {
                    welcome
                } else {
                    mailboxes
                }
            }
            .background(Color.paper.ignoresSafeArea())
            .overlay(alignment: .bottomTrailing) { floatingTiles }
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
        ZStack(alignment: .top) {
            DitherBackground()
            RetroWindow(title: tr("欢迎使用 RetroMail", "Welcome to RetroMail"), fill: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "envelope.open")
                            .font(.system(size: 34))
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
            .padding(.top, 30)
        }
    }

    // MARK: 邮箱（全屏）

    private var mailboxes: some View {
        VStack(spacing: 0) {
            StripedTitleBar(title: tr("邮箱", "Mailboxes"))
            List {
                ForEach(store.accounts) { a in
                    Section {
                        accountRows(a)
                    } header: {
                        accountHeader(a)
                    }
                }
                Color.clear
                    .frame(height: 90)
                    .listRowBackground(Color.paper)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.paper)
            .environment(\.defaultMinListRowHeight, 1)
            .refreshable { await center.loadAll() }
        }
    }

    private func accountHeader(_ a: MailAccount) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.square")
            Text(a.name.isEmpty ? a.email : "\(a.name)  \(a.email)")
                .font(RT.font(12, .bold))
                .lineLimit(1)
            Spacer()
            if center.loadingAccounts.contains(a.id) {
                Image(systemName: "hourglass").font(.system(size: 12))
            }
        }
        .foregroundColor(.paper)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ink)
        .listRowInsets(EdgeInsets())
    }

    @ViewBuilder
    private func accountRows(_ a: MailAccount) -> some View {
        if let err = center.folderErrors[a.id], center.folders[a.id] == nil {
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
            .foregroundColor(.ink)
            .padding(12)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.paper)
        } else if let folders = center.folders[a.id] {
            ForEach(folders) { f in
                folderRow(a, f)
            }
        } else {
            RetroBusy(text: tr("正在连接服务器…", "Connecting…"))
                .padding(12)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.paper)
        }
    }

    private func folderRow(_ a: MailAccount, _ f: MailFolder) -> some View {
        let count = center.unread[center.unreadKey(a.id, f.path)] ?? 0
        return Button {
            if f.selectable { path.append(Route.folder(a, f)) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: f.role.icon)
                    .font(.system(size: 15))
                    .frame(width: 22)
                Text(f.displayName)
                    .font(RT.font(15, count > 0 ? .bold : .regular))
                    .lineLimit(1)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(RT.font(12, .bold))
                        .foregroundColor(.paper)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.ink))
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).opacity(0.5)
            }
            .padding(.leading, 12 + CGFloat(f.depth) * 18)
            .padding(.trailing, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .opacity(f.selectable ? 1 : 0.4)
            .overlay(alignment: .bottom) { RetroDivider(dotted: true).opacity(0.5) }
        }
        .buttonStyle(InvertOnPressStyle())
        .disabled(!f.selectable)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.paper)
    }

    // MARK: 浮动按钮

    private var floatingTiles: some View {
        HStack(spacing: 14) {
            TileButton(symbol: "gearshape", label: tr("控制面板", "Settings"), size: 60) {
                path.append(Route.settings)
            }
            if !store.accounts.isEmpty {
                TileButton(symbol: "square.and.pencil", label: tr("新邮件", "Compose"), size: 60) {
                    compose = ComposeRequest()
                }
            }
        }
        .padding(.trailing, 18)
        .padding(.bottom, 18)
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
                Text(tr("版本 2.0", "Version 2.0")).font(RT.font(12))
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
