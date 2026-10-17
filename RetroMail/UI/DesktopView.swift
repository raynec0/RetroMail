import SwiftUI

enum Route: Hashable {
    case folder(MailAccount, MailFolder)
    case account(MailAccount?)
    case settings
}

struct DesktopView: View {
    @ObservedObject private var store = AccountStore.shared
    @ObservedObject private var center = MailCenter.shared
    @State private var path = NavigationPath()
    @State private var compose: ComposeRequest?
    @State private var showAbout = false

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                menuBar
                ZStack(alignment: .bottomTrailing) {
                    DitherBackground()
                    if store.accounts.isEmpty {
                        welcome
                    } else {
                        mailboxWindow
                    }
                    desktopIcons
                }
            }
            .background(Color.white.ignoresSafeArea())
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
                Button("新邮件") { compose = ComposeRequest() }
                    .disabled(store.accounts.isEmpty)
                Button("全部刷新") { Task { await center.loadAll() } }
            } label: {
                Text("文件")
            }
            Menu {
                ForEach(store.accounts) { a in
                    if let inbox = center.folder(a, role: .inbox) {
                        Button("\(a.email) · 收件箱") { path.append(Route.folder(a, inbox)) }
                    }
                }
                if store.accounts.isEmpty {
                    Text("尚无账户")
                }
            } label: {
                Text("邮箱")
            }
            Menu {
                Button("控制面板…") { path.append(Route.settings) }
                Button("添加账户…") { path.append(Route.account(nil)) }
                Divider()
                Button("关于 RetroMail…") { showAbout = true }
            } label: {
                Text("特别")
            }
        }
    }

    // MARK: 首次使用

    private var welcome: some View {
        VStack {
            RetroWindow(title: "欢迎使用 RetroMail", fill: false) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "envelope.open")
                            .font(.system(size: 34))
                        Text("还没有邮箱账户。\n\n添加一个 IMAP/SMTP 账户即可开始收发邮件。企业邮箱需要在管理后台开启 IMAP 服务。")
                            .font(RT.font(13))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        Button("添加账户…") { path.append(Route.account(nil)) }
                            .buttonStyle(RetroButtonStyle(isDefault: true))
                    }
                }
                .padding(16)
                .foregroundColor(.black)
            }
            .padding(20)
            .padding(.top, 30)
            Spacer()
        }
    }

    // MARK: 邮箱窗口

    private var mailboxWindow: some View {
        RetroWindow(title: "邮箱") {
            List {
                ForEach(store.accounts) { a in
                    Section {
                        accountRows(a)
                    } header: {
                        accountHeader(a)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 1)
            .refreshable { await center.loadAll() }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 100)
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
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black)
        .listRowInsets(EdgeInsets())
    }

    @ViewBuilder
    private func accountRows(_ a: MailAccount) -> some View {
        if let err = center.folderErrors[a.id], center.folders[a.id] == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("⚠ \(err)")
                    .font(RT.font(12))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("重试") { Task { await center.loadFolders(a) } }
                        .buttonStyle(RetroButtonStyle(compact: true))
                    Button("账户设置") { path.append(Route.account(a)) }
                        .buttonStyle(RetroButtonStyle(compact: true))
                }
            }
            .foregroundColor(.black)
            .padding(12)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.white)
        } else if let folders = center.folders[a.id] {
            ForEach(folders) { f in
                folderRow(a, f)
            }
        } else {
            RetroBusy(text: "正在连接服务器…")
                .padding(12)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.white)
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
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.black))
                }
            }
            .padding(.leading, 12 + CGFloat(f.depth) * 18)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .opacity(f.selectable ? 1 : 0.4)
        }
        .buttonStyle(InvertOnPressStyle())
        .disabled(!f.selectable)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.white)
    }

    // MARK: 桌面图标

    private var desktopIcons: some View {
        HStack(spacing: 18) {
            if !store.accounts.isEmpty {
                DesktopIcon(symbol: "square.and.pencil", label: "新邮件") { compose = ComposeRequest() }
            }
            DesktopIcon(symbol: "gearshape", label: "控制面板") { path.append(Route.settings) }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 14)
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
                Text("版本 1.0").font(RT.font(12))
                RetroDivider()
                Text("一个黑白的、老派的邮件客户端。\nIMAP · SMTP · 附件 · 搜索 · 草稿 · 后台通知")
                    .font(RT.font(12))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("好") { onClose() }
                    .buttonStyle(RetroButtonStyle(isDefault: true))
            }
            .foregroundColor(.black)
        }
    }
}
