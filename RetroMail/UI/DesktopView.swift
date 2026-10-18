import SwiftUI

enum Route: Hashable {
    case folder(MailAccount, MailFolder)
    case account(MailAccount?)
    case settings
}

extension FolderRole {
    /// iPhone OS 3 邮箱列表里的小图标
    var ios3Symbol: String {
        switch self {
        case .inbox: return "tray.fill"
        case .drafts: return "doc.text"
        case .sent: return "paperplane"
        case .junk: return "xmark.bin"
        case .trash: return "trash"
        case .archive: return "archivebox"
        case .other: return "folder"
        }
    }
}

/// 首页：iPhone OS 3 邮件的“邮箱”列表。
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
                IOS3NavBar(title: tr("邮箱", "Mailboxes")) {
                    Button(tr("设置", "Settings")) { path.append(Route.settings) }
                        .buttonStyle(BarButtonStyle())
                } trailing: {
                    Button {
                        path.append(Route.account(nil))
                    } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .bold))
                    }
                    .buttonStyle(BarButtonStyle())
                }
                if store.accounts.isEmpty {
                    welcome
                } else {
                    mailboxes
                }
                toolbar
            }
            .background(PinstripeBackground())
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
        .sheetHost()
        .task {
            await center.loadAll()
        }
    }

    // MARK: 首次使用

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 18) {
                RetroGroup(tr("欢迎使用 RetroMail", "Welcome to RetroMail")) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 30))
                            .foregroundColor(IOS3.value)
                        Text(tr("还没有邮箱账户。添加一个 IMAP/SMTP 账户即可开始收发邮件。企业邮箱需要在管理后台开启 IMAP 服务。",
                                "No mail accounts yet. Add an IMAP/SMTP account to start. Company mailboxes may need IMAP enabled by your administrator."))
                            .font(RT.font(15))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button(tr("添加账户", "Add Account")) { path.append(Route.account(nil)) }
                    .buttonStyle(RetroButtonStyle(isDefault: true))
            }
            .padding(10)
        }
    }

    // MARK: 邮箱列表（iPhone OS 3 分组按钮）

    private var mailboxes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(store.accounts) { a in
                    accountSection(a)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .refreshable { await center.loadAll() }
    }

    private func accountSection(_ a: MailAccount) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(a.name.isEmpty ? a.email : a.name)
                    .font(RT.font(17, .bold))
                    .lineLimit(1)
                if !a.name.isEmpty {
                    Text(a.email)
                        .font(RT.font(13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(0.8)
                }
                Spacer(minLength: 0)
                if center.loadingAccounts.contains(a.id) {
                    ProgressView().scaleEffect(0.7).tint(IOS3.groupHeader)
                }
            }
            .foregroundColor(IOS3.groupHeader)
            .shadow(color: IOS3.groupHeaderShadow, radius: 0, x: 0, y: 1)
            .padding(.horizontal, 8)

            GroupedBox {
                accountRows(a)
            }
        }
    }

    @ViewBuilder
    private func accountRows(_ a: MailAccount) -> some View {
        if let err = center.folderErrors[a.id], center.folders[a.id] == nil {
            VStack(alignment: .leading, spacing: 10) {
                Text(err)
                    .font(RT.font(14))
                    .foregroundColor(IOS3.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(tr("重试", "Retry")) { Task { await center.loadFolders(a) } }
                        .buttonStyle(RetroButtonStyle(compact: true))
                    Button(tr("账户设置", "Account Settings")) { path.append(Route.account(a)) }
                        .buttonStyle(RetroButtonStyle(compact: true))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let folders = center.folders[a.id] {
            let shown = folders.filter(\.selectable)
            ForEach(shown) { f in
                Button {
                    path.append(Route.folder(a, f))
                } label: {
                    MailboxRowLabel(folder: f, count: center.unread[center.unreadKey(a.id, f.path)] ?? 0,
                                    last: f.id == shown.last?.id)
                }
                .buttonStyle(GroupedRowStyle())
            }
        } else {
            RetroBusy(text: tr("正在连接…", "Connecting…"))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 底部工具栏

    private var toolbar: some View {
        IOS3Toolbar {
            ToolbarIcon(symbol: "arrow.clockwise", label: tr("刷新", "Refresh")) {
                Task { await center.loadAll() }
            }
            .frame(width: 54)
            .disabled(store.accounts.isEmpty)
            ToolbarStatus(text: center.loadingAccounts.isEmpty
                          ? Fmt.updated(center.lastUpdated)
                          : tr("正在检查邮件…", "Checking for Mail…"))
            Button {
                showAbout = true
            } label: {
                Image(systemName: "info.circle").font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
            .frame(width: 36)
            ToolbarIcon(symbol: "square.and.pencil", label: tr("新邮件", "Compose")) {
                compose = ComposeRequest()
            }
            .frame(width: 54)
            .disabled(store.accounts.isEmpty)
        }
    }
}

/// iPhone OS 3 分组表格的外框（白色圆角，灰色描边，下方一道白色高光）。
struct GroupedBox<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(IOS3.cell)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(IOS3.groupBorder, lineWidth: 1))
        .shadow(color: IOS3.groupHeaderShadow.opacity(0.6), radius: 0, x: 0, y: 1)
    }
}

/// 分组里的一行：像一个按钮——浅浅的渐变底，按下时变成 iOS 蓝。
struct GroupedRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(configuration.isPressed ? .white : .ink)
            .environment(\.rowPressed, configuration.isPressed)
            .background {
                if configuration.isPressed {
                    IOS3.selection
                } else {
                    LinearGradient(colors: [IOS3.cell, IOS3.cellBottom], startPoint: .top, endPoint: .bottom)
                }
            }
    }
}

/// 邮箱列表的一行：光泽小图标 + 名称 + 未读数 + 箭头。
struct MailboxRowLabel: View {
    let folder: MailFolder
    let count: Int
    var last = false
    @Environment(\.rowPressed) private var pressed

    var body: some View {
        let nested = folder.depth > 0
        HStack(spacing: 10) {
            if nested {
                Color.clear.frame(width: CGFloat(folder.depth) * 16)
            }
            GlossyIcon(symbol: folder.role.springSymbol, colors: folder.iconColors, size: nested ? 25 : 29)
                .scaleEffect(0.98)
            Text(folder.displayName)
                .font(RT.font(nested ? 16 : 17, .bold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if count > 0 { CountPill(count: count) }
            Chevron()
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .frame(minHeight: nested ? 42 : 46)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if !last {
                Rectangle().fill(pressed ? Color.clear : IOS3.groupBorder).frame(height: 1)
            }
        }
    }
}

struct FolderRowLabel: View {
    let folder: MailFolder
    let count: Int
    @Environment(\.rowPressed) private var pressed

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: folder.role.ios3Symbol)
                .font(.system(size: 19, weight: .regular))
                .foregroundColor(pressed ? .white : IOS3.value)
                .frame(width: 28)
            Text(folder.displayName)
                .font(RT.font(19, .bold))
                .lineLimit(1)
            Spacer(minLength: 6)
            if count > 0 { CountPill(count: count) }
            Chevron()
        }
        .padding(.leading, 12 + CGFloat(folder.depth) * 20)
        .padding(.trailing, 10)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(pressed ? Color.clear : IOS3.separator).frame(height: 1)
        }
    }
}

struct AboutBox: View {
    let onClose: () -> Void

    var body: some View {
        RetroDialog {
            VStack(spacing: 10) {
                Text("RetroMail").font(RT.font(18, .bold))
                Text(tr("版本 3.2", "Version 3.2")).font(RT.font(14))
                Text(tr("iPhone OS 3 风格的邮件客户端。\nIMAP · SMTP · 会话 · 富文本 · AI",
                        "A mail client in the style of iPhone OS 3.\nIMAP · SMTP · Threads · Rich text · AI"))
                    .font(RT.font(14))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(tr("好", "OK")) { onClose() }
                    .buttonStyle(IOS3AlertButtonStyle(primary: true))
                    .padding(.top, 4)
            }
            .shadow(color: .black.opacity(0.5), radius: 0, x: 0, y: -1)
        }
    }
}
