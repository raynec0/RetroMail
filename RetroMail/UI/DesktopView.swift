import SwiftUI

enum Route: Hashable {
    case folder(MailAccount, MailFolder)
    case account(MailAccount?)
    case settings
    case folderEdit(MailAccount, MailFolder?, parent: MailFolder?)
    case followUps
    case followUpMessage(String)
    case message(MailAccount, MailFolder, MessageSummary)
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
    @State private var editing: Set<UUID> = []
    @ObservedObject private var followUps = FollowUpStore.shared

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
                case .folderEdit(let a, let f, let parent):
                    FolderEditView(account: a, folder: f, parent: parent)
                case .followUps:
                    FollowUpBoardView()
                case .followUpMessage(let id):
                    FollowUpMessageView(id: id)
                case .message(let a, let f, let m):
                    MessageHostView(account: a, folder: f, summary: m)
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
        .overlay(alignment: .bottom) {
            if let t = center.toast {
                ToastView(toast: t) { center.toast = nil }
                    .padding(.bottom, 64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: center.toast)
        .onChange(of: center.openRequest) { req in
            guard let r = req else { return }
            center.openRequest = nil
            open(r)
        }
        .onChange(of: center.openFollowUp) { id in
            guard let id = id else { return }
            center.openFollowUp = nil
            path = NavigationPath()
            path.append(Route.followUps)
            path.append(Route.followUpMessage(id))
        }
        .sheetHost()
        .task {
            await center.loadAll()
        }
    }

    /// 点了新邮件通知：打开那封邮件（先进收件箱，返回时就在列表里）。
    private func open(_ r: OpenRequest) {
        guard let a = store.accounts.first(where: { $0.id == r.account }) else { return }
        let folder = center.folders[a.id]?.first { $0.path == r.folder } ?? MailFolder(path: r.folder, delimiter: nil, flags: [])
        path = NavigationPath()
        path.append(Route.folder(a, folder))
        Task {
            var summary = DiskCache.loadList(account: a.id, folder: r.folder).first { $0.uid == r.uid }
            if summary == nil {
                let c = center.client(for: a, .interactive)
                summary = (try? await c.perform { try await $0.fetchSince(r.folder, uid: r.uid) })?.first { $0.uid == r.uid }
            }
            if let m = summary { path.append(Route.message(a, folder, m)) }
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
                followUpBar
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

    /// 置顶的“跟进事项”按钮：旗标、提醒、截止日期和备注都集中在这里。
    private var followUpBar: some View {
        Button { path.append(Route.followUps) } label: {
            HStack(spacing: 12) {
                Image("fu-board")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 38, height: 38)
                    .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("跟进事项", "Follow-ups"))
                        .font(RT.font(18, .bold))
                    Text(followUps.summaryLine)
                        .font(RT.font(12))
                        .opacity(0.7)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if followUps.overdueCount > 0 {
                    Text("\(followUps.overdueCount)")
                        .font(RT.font(14, .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(IOS3.red))
                        .overlay(Capsule().stroke(Color.white, lineWidth: 1.5))
                } else if followUps.openCount > 0 {
                    CountPill(count: followUps.openCount)
                }
                Chevron()
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(MailboxBarStyle())
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
                if center.folders[a.id] != nil {
                    Button(editing.contains(a.id) ? tr("完成", "Done") : tr("编辑", "Edit")) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            if editing.contains(a.id) { editing.remove(a.id) } else { editing.insert(a.id) }
                        }
                    }
                    .buttonStyle(RetroButtonStyle(isDefault: editing.contains(a.id), compact: true))
                    .shadow(radius: 0)
                }
            }
            .foregroundColor(IOS3.groupHeader)
            .shadow(color: IOS3.groupHeaderShadow, radius: 0, x: 0, y: 1)
            .padding(.horizontal, 8)

            VStack(spacing: 8) {
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
            .background(RoundedRectangle(cornerRadius: 10).fill(IOS3.cell))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(IOS3.groupBorder, lineWidth: 1))
        } else if let folders = center.folders[a.id] {
            let shown = folders.filter(\.selectable)
            let isEditing = editing.contains(a.id)
            ForEach(shown) { f in
                Button {
                    path.append(isEditing ? Route.folderEdit(a, f, parent: nil) : Route.folder(a, f))
                } label: {
                    MailboxBarLabel(folder: f, icon: f.icon(for: a.id),
                                    count: center.unread[center.unreadKey(a.id, f.path)] ?? 0,
                                    showIcon: settings.mailboxIcons, editing: isEditing)
                }
                .buttonStyle(MailboxBarStyle(nested: f.depth > 0))
                .padding(.leading, CGFloat(min(f.depth, 3)) * 22)
                .contextMenu {
                    Button(tr("编辑邮箱…", "Edit Mailbox…")) { path.append(Route.folderEdit(a, f, parent: nil)) }
                    Button(tr("新建子邮箱…", "New Mailbox Inside…")) { path.append(Route.folderEdit(a, nil, parent: f)) }
                }
            }
            if isEditing {
                Button { path.append(Route.folderEdit(a, nil, parent: nil)) } label: {
                    HStack(spacing: 10) {
                        Text("+").font(RT.font(24, .bold))
                        Text(tr("新建邮箱", "New Mailbox")).font(RT.font(17, .bold))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .foregroundColor(IOS3.value)
                    .contentShape(Rectangle())
                }
                .buttonStyle(MailboxBarStyle(nested: true))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(IOS3.value.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .padding(3)
                        .allowsHitTesting(false)
                )
            }
        } else {
            RetroBusy(text: tr("正在连接…", "Connecting…"))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(IOS3.cell))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(IOS3.groupBorder, lineWidth: 1))
        }
    }

    // MARK: 底部工具栏

    private var toolbar: some View {
        IOS3Toolbar {
            ToolbarIcon(symbol: "arrow.clockwise", label: tr("刷新", "Refresh")) {
                Task {
                    await center.loadAll()
                    await center.checkAll(lists: false)
                }
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

extension MailFolder {
    /// 首页按钮用的图标（Oxygen / Tango 图标集，见 README 致谢）
    var assetIcon: String {
        switch role {
        case .inbox: return "mbx-inbox"
        case .sent: return "mbx-sent"
        case .drafts: return "mbx-drafts"
        case .junk: return "mbx-junk"
        case .trash: return "mbx-trash"
        case .archive: return "mbx-archive"
        case .other:
            let colors = ["blue", "orange", "green", "yellow", "violet", "red"]
            var h: UInt32 = 2166136261
            for b in path.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
            return "mbx-folder-" + colors[Int(h % UInt32(colors.count))]
        }
    }
}

/// 首页的长条玻璃按钮（iPhone OS 3 大按钮风格）：上亮下暗的渐变、上半部高光、深色描边、底部白色压印线。
struct MailboxBarStyle: ButtonStyle {
    var nested = false

    func makeBody(configuration: Configuration) -> some View {
        MailboxBarBody(configuration: configuration, nested: nested)
    }
}

private struct MailboxBarBody: View {
    let configuration: ButtonStyleConfiguration
    let nested: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let pressed = configuration.isPressed
        let dark = scheme == .dark
        let r: CGFloat = nested ? 9 : 11
        let shape = RoundedRectangle(cornerRadius: r, style: .continuous)
        configuration.label
            .foregroundColor(pressed ? .white : (dark ? HexColor.color("#F2F2F2") : HexColor.color("#1E2733")))
            .environment(\.rowPressed, pressed)
            .frame(maxWidth: .infinity, minHeight: nested ? 46 : 56)
            .background {
                ZStack {
                    if pressed {
                        shape.fill(IOS3.selection)
                    } else {
                        shape.fill(LinearGradient(
                            stops: dark
                                ? [.init(color: HexColor.color("#4A4A4E"), location: 0), .init(color: HexColor.color("#2E2E31"), location: 0.5),
                                   .init(color: HexColor.color("#232326"), location: 0.5), .init(color: HexColor.color("#1A1A1C"), location: 1)]
                                : [.init(color: HexColor.color("#FFFFFF"), location: 0), .init(color: HexColor.color("#F1F3F6"), location: 0.5),
                                   .init(color: HexColor.color("#E4E8ED"), location: 0.5), .init(color: HexColor.color("#D5DBE2"), location: 1)],
                            startPoint: .top, endPoint: .bottom))
                    }
                    shape.strokeBorder(Color.white.opacity(dark ? 0.12 : 0.9), lineWidth: 1).padding(1)
                    shape.stroke(dark ? Color.black : HexColor.color("#8E98A5"), lineWidth: 1)
                }
            }
            .shadow(color: dark ? .black.opacity(0.7) : .white.opacity(0.85), radius: 0, x: 0, y: 1)
            .shadow(color: .black.opacity(dark ? 0.4 : 0.12), radius: 2, x: 0, y: 1)
            .scaleEffect(pressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

struct MailboxBarLabel: View {
    let folder: MailFolder
    var icon: String? = nil
    let count: Int
    var showIcon = true
    var editing = false
    var displayName: String? = nil
    @Environment(\.rowPressed) private var pressed

    var body: some View {
        let nested = folder.depth > 0
        HStack(spacing: 12) {
            if showIcon {
                Image(icon ?? folder.assetIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: nested ? 30 : 38, height: nested ? 30 : 38)
                    .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)
            }
            Text(displayName ?? folder.displayName)
                .font(RT.font(nested ? 16 : 18, .bold))
                .shadow(color: pressed ? .black.opacity(0.3) : .white.opacity(0.6), radius: 0, x: 0, y: pressed ? -1 : 1)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if editing {
                Text(tr("编辑", "Edit"))
                    .font(RT.font(14, .bold))
                    .foregroundColor(pressed ? .white : IOS3.dateBlue)
            } else if count > 0 {
                CountPill(count: count)
            }
            Chevron()
        }
        .padding(.leading, showIcon ? 10 : 16)
        .padding(.trailing, 12)
        .contentShape(Rectangle())
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

/// 底部黑色半透明提示条，带“撤销”。
struct ToastView: View {
    let toast: MailToast
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text)
                .font(RT.font(15, .bold))
                .foregroundColor(.white)
                .lineLimit(1)
            if let undo = toast.undo {
                Button(tr("撤销", "Undo")) {
                    undo()
                    onClose()
                }
                .font(RT.font(15, .bold))
                .foregroundColor(HexColor.color("#8FC1FF"))
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.78))
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
        .onTapGesture { onClose() }
    }
}

struct AboutBox: View {
    let onClose: () -> Void

    var body: some View {
        RetroDialog {
            VStack(spacing: 10) {
                Text("RetroMail").font(RT.font(18, .bold))
                Text(tr("版本 3.5", "Version 3.5")).font(RT.font(14))
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
