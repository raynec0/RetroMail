import SwiftUI

@MainActor
final class MessageListModel: ObservableObject {
    let account: MailAccount
    let folder: MailFolder

    @Published var messages: [MessageSummary] = []
    @Published var searchResults: [MessageSummary]?
    @Published var query = ""
    @Published var loading = false
    @Published var searching = false
    @Published var hasMore = false
    @Published var error: String?
    private var loadingMore = false
    private var didInitialLoad = false

    init(account: MailAccount, folder: MailFolder) {
        self.account = account
        self.folder = folder
    }

    var client: IMAPClient { MailCenter.shared.client(for: account) }
    var visible: [MessageSummary] { searchResults ?? messages }

    /// 按会话分组后的列表（关闭分组时每封邮件单独一行），按最近收到时间排序。
    var conversations: [Conversation] {
        let list = visible.sorted(by: MessageSummary.newestFirst)
        if AppSettings.shared.threaded {
            return Threading.group(list)
        }
        return list.map { Conversation(messages: [$0]) }
    }

    func initialLoad() async {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        messages = DiskCache.loadList(account: account.id, folder: folder.path).sorted(by: MessageSummary.newestFirst)
        await refresh()
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        let path = folder.path
        do {
            let result = try await client.perform { try await $0.fetchLatest(path, limit: 60) }
            messages = result.messages.sorted(by: MessageSummary.newestFirst)
            hasMore = result.hasMore
            DiskCache.saveList(Array(messages.prefix(120)), account: account.id, folder: path)
            if folder.role == .inbox, let top = messages.map(\.uid).max() {
                BackgroundRefresh.noteSeen(account: account.id, nextUID: top + 1)
            }
            let unseen = messages.filter { !$0.seen }.count
            if !hasMore || unseen == 0 {
                MailCenter.shared.unread[MailCenter.shared.unreadKey(account.id, path)] = unseen
            } else {
                Task { await MailCenter.shared.refreshUnread(account) }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMore() async {
        guard hasMore, !loadingMore, searchResults == nil, let minUID = messages.map(\.uid).min() else { return }
        loadingMore = true
        defer { loadingMore = false }
        let path = folder.path
        do {
            let result = try await client.perform { try await $0.fetchOlder(path, below: minUID, limit: 60) }
            let existing = Set(messages.map(\.uid))
            messages = (messages + result.messages.filter { !existing.contains($0.uid) }).sorted(by: MessageSummary.newestFirst)
            hasMore = result.hasMore
        } catch {
            self.error = error.localizedDescription
        }
    }

    func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchResults = nil
            return
        }
        searching = true
        defer { searching = false }
        let path = folder.path
        do {
            let found = try await client.perform { try await $0.search(path, query: q, limit: 150) }
            searchResults = found.sorted(by: MessageSummary.newestFirst)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clearSearch() {
        query = ""
        searchResults = nil
    }

    // MARK: 修改操作（先本地更新，再同步服务器）

    private func update(_ uids: [Int], _ change: (inout MessageSummary) -> Void) {
        let set = Set(uids)
        for i in messages.indices where set.contains(messages[i].uid) { change(&messages[i]) }
        if var r = searchResults {
            for i in r.indices where set.contains(r[i].uid) { change(&r[i]) }
            searchResults = r
        }
    }

    private func remove(_ uids: [Int]) {
        let set = Set(uids)
        messages.removeAll { set.contains($0.uid) }
        searchResults?.removeAll { set.contains($0.uid) }
    }

    func setSeen(_ uids: [Int], _ on: Bool) async {
        let changed = visible.filter { uids.contains($0.uid) && $0.seen != on }.count
        guard changed > 0 || !on else { return }
        update(uids) { $0.set("\\Seen", on) }
        MailCenter.shared.adjustUnread(account, folder.path, by: on ? -changed : changed)
        let path = folder.path
        await sync { try await $0.store(path, uids: uids, flag: "\\Seen", add: on) }
    }

    func setFlagged(_ uids: [Int], _ on: Bool) async {
        update(uids) { $0.set("\\Flagged", on) }
        let path = folder.path
        await sync { try await $0.store(path, uids: uids, flag: "\\Flagged", add: on) }
    }

    func delete(_ uids: [Int]) async {
        let unseenRemoved = visible.filter { uids.contains($0.uid) && !$0.seen }.count
        remove(uids)
        MailCenter.shared.adjustUnread(account, folder.path, by: -unseenRemoved)
        let trash = MailCenter.shared.folder(account, role: .trash)?.path
        let path = folder.path
        await sync { try await $0.delete(path, uids: uids, trash: trash) }
    }

    func move(_ uids: [Int], to dest: MailFolder) async {
        remove(uids)
        let path = folder.path
        await sync { try await $0.move(path, uids: uids, to: dest.path) }
        Task { await MailCenter.shared.refreshUnread(account) }
    }

    private func sync(_ op: (IMAPConnection) async throws -> Void) async {
        do {
            try await client.perform(op)
        } catch {
            self.error = error.localizedDescription
            await refresh()
        }
    }
}

struct MessageListView: View {
    let account: MailAccount
    let folder: MailFolder
    @StateObject private var model: MessageListModel
    @ObservedObject private var center = MailCenter.shared
    @EnvironmentObject private var settings: AppSettings
    @State private var openConversation: Conversation?
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var showMove = false
    @State private var compose: ComposeRequest?

    init(account: MailAccount, folder: MailFolder) {
        self.account = account
        self.folder = folder
        _model = StateObject(wrappedValue: MessageListModel(account: account, folder: folder))
    }

    private var showRecipients: Bool { folder.role == .sent || folder.role == .drafts }

    var body: some View {
        let convs = model.conversations
        RetroScreen(title: folder.displayName) {
            VStack(spacing: 0) {
                searchBar
                RetroDivider()
                infoBar(convs)
                RetroDivider()
                content(convs)
                if selecting { selectionBar(convs) }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !selecting {
                TileButton(symbol: "square.and.pencil", label: tr("新邮件", "Compose"), size: 58) {
                    compose = ComposeRequest(account: account)
                }
                .padding(18)
            }
        }
        .retroAlert($model.error)
        .task { await model.initialLoad() }
        .navigationDestination(isPresented: Binding(get: { openConversation != nil },
                                                    set: { if !$0 { openConversation = nil } })) {
            if let c = openConversation {
                ConversationView(list: model, conversation: c)
            }
        }
        .sheet(isPresented: $showMove) {
            FolderPickerView(account: account, excluding: folder.path) { dest in
                let uids = selectedUIDs(convs)
                selection = []
                selecting = false
                Task { await model.move(uids, to: dest) }
            }
            .preferredColorScheme(settings.colorScheme)
        }
        .fullScreenCover(item: $compose) {
            ComposeView(request: $0)
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
        }
    }

    private func selectedUIDs(_ convs: [Conversation]) -> [Int] {
        convs.filter { selection.contains($0.id) }.flatMap(\.uids)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .bold))
                TextField(tr("搜索主题 / 发件人 / 收件人", "Search subject / from / to"), text: $model.query)
                    .font(RT.font(13))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await model.search() } }
                if model.searching {
                    Image(systemName: "hourglass").font(.system(size: 12))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .overlay(Rectangle().stroke(Color.ink, lineWidth: 1))
            .background(Rectangle().fill(Color.ink).offset(x: 1.5, y: 1.5))

            if model.searchResults != nil || !model.query.isEmpty {
                Button(tr("取消", "Cancel")) { model.clearSearch() }
                    .buttonStyle(RetroButtonStyle(compact: true))
            }
            Button(selecting ? tr("完成", "Done") : tr("选择", "Select")) {
                selecting.toggle()
                selection = []
            }
            .buttonStyle(RetroButtonStyle(compact: true))
        }
        .foregroundColor(.ink)
        .padding(10)
    }

    private func infoBar(_ convs: [Conversation]) -> some View {
        let unread = center.unread[center.unreadKey(account.id, folder.path)] ?? model.messages.filter { !$0.seen }.count
        let label: String
        if let r = model.searchResults {
            label = tr("找到 \(r.count) 封", "\(r.count) found")
        } else if selecting {
            label = tr("已选择 \(selection.count) 项", "\(selection.count) selected")
        } else if settings.threaded {
            label = tr("\(convs.count) 个会话 · \(model.messages.count)\(model.hasMore ? "+" : "") 封", "\(convs.count) threads · \(model.messages.count)\(model.hasMore ? "+" : "") msgs")
        } else {
            label = tr("\(model.messages.count)\(model.hasMore ? "+" : "") 封邮件", "\(model.messages.count)\(model.hasMore ? "+" : "") messages")
        }
        return HStack {
            Text(label)
            Spacer()
            if model.loading {
                Image(systemName: "hourglass")
            }
            Text(tr("\(unread) 封未读", "\(unread) unread"))
        }
        .font(RT.font(11))
        .foregroundColor(.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func content(_ convs: [Conversation]) -> some View {
        if convs.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                if model.loading || model.searching {
                    RetroBusy(text: tr("正在接收…", "Receiving…"))
                } else {
                    Text(model.searchResults != nil ? tr("没有找到匹配的邮件", "No matching messages") : tr("此邮箱中没有邮件", "No messages"))
                        .font(RT.font(13))
                    Button(tr("刷新", "Refresh")) { Task { await model.refresh() } }
                        .buttonStyle(RetroButtonStyle(compact: true))
                }
                Spacer()
            }
            .foregroundColor(.ink)
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(convs) { c in
                    row(c)
                }
                if model.hasMore && model.searchResults == nil {
                    HStack {
                        Spacer()
                        RetroBusy(text: tr("载入更早的邮件…", "Loading older…"))
                        Spacer()
                    }
                    .padding(.vertical, 14)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.paper)
                    .onAppear { Task { await model.loadMore() } }
                }
                Color.clear.frame(height: 80)
                    .listRowBackground(Color.paper)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.paper)
            .refreshable { await model.refresh() }
        }
    }

    private func row(_ c: Conversation) -> some View {
        let isSelected = selection.contains(c.id)
        let unread = c.unread > 0
        return ConversationRow(conversation: c, selecting: selecting, selected: isSelected,
                               showRecipients: showRecipients, threaded: settings.threaded)
            .contentShape(Rectangle())
            .onTapGesture {
                if selecting {
                    if isSelected { selection.remove(c.id) } else { selection.insert(c.id) }
                } else {
                    openConversation = c
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.paper)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    Task { await model.delete(c.uids) }
                } label: {
                    Label(tr("删除", "Delete"), systemImage: "trash")
                }
                Button {
                    Task { await model.setFlagged(c.uids, !c.flagged) }
                } label: {
                    Label(c.flagged ? tr("取消旗标", "Unflag") : tr("旗标", "Flag"), systemImage: "flag")
                }
                .tint(.gray)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    Task { await model.setSeen(c.uids, unread) }
                } label: {
                    Label(unread ? tr("已读", "Read") : tr("未读", "Unread"), systemImage: unread ? "envelope.open" : "envelope.badge")
                }
                .tint(.black)
            }
    }

    private func selectionBar(_ convs: [Conversation]) -> some View {
        let uids = selectedUIDs(convs)
        return VStack(spacing: 0) {
            RetroDivider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    TileButton(symbol: "checklist", label: tr("全选", "All"), size: 50) {
                        selection = Set(convs.map(\.id))
                    }
                    TileButton(symbol: "envelope.open", label: tr("已读", "Read"), size: 50) { finish { await model.setSeen(uids, true) } }
                    TileButton(symbol: "envelope.badge", label: tr("未读", "Unread"), size: 50) { finish { await model.setSeen(uids, false) } }
                    TileButton(symbol: "flag", label: tr("旗标", "Flag"), size: 50) { finish { await model.setFlagged(uids, true) } }
                    TileButton(symbol: "folder", label: tr("移动", "Move"), size: 50) { if !selection.isEmpty { showMove = true } }
                    TileButton(symbol: "trash", label: tr("删除", "Delete"), size: 50) { finish { await model.delete(uids) } }
                }
                .padding(10)
                .padding(.trailing, 4)
            }
        }
        .background(Color.paper)
    }

    private func finish(_ op: @escaping () async -> Void) {
        guard !selection.isEmpty else { return }
        selection = []
        selecting = false
        Task { await op() }
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    var selecting: Bool
    var selected: Bool
    var showRecipients: Bool
    var threaded: Bool

    private var people: String {
        let m = conversation.latest
        if showRecipients {
            let names = m.to.map(\.display).joined(separator: ", ")
            return names.isEmpty ? tr("（无收件人）", "(No recipients)") : tr("致：", "To: ") + names
        }
        if threaded && conversation.count > 1 {
            var seen = Set<String>()
            let names = conversation.messages.compactMap { $0.from?.display }.filter { seen.insert($0).inserted }
            return names.prefix(3).joined(separator: ", ")
        }
        return m.from?.display ?? tr("（未知发件人）", "(Unknown sender)")
    }

    var body: some View {
        let m = conversation.latest
        let unread = conversation.unread > 0
        HStack(alignment: .top, spacing: 8) {
            if selecting {
                ZStack {
                    Rectangle().fill(Color.paper)
                    Rectangle().stroke(Color.ink, lineWidth: 1)
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
                    }
                }
                .frame(width: 16, height: 16)
                .padding(.top, 2)
            }
            Text(unread ? "◆" : " ")
                .font(RT.font(11, .bold))
                .frame(width: 10)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(people)
                        .font(RT.font(14, unread ? .bold : .regular))
                        .lineLimit(1)
                    if threaded && conversation.count > 1 {
                        Text("\(conversation.count)")
                            .font(RT.font(10, .bold))
                            .padding(.horizontal, 4)
                            .overlay(Rectangle().stroke(Color.ink, lineWidth: 1))
                    }
                    Spacer(minLength: 4)
                    if conversation.answered {
                        Image(systemName: "arrowshape.turn.up.left").font(.system(size: 10))
                    }
                    if conversation.hasAttachment {
                        Image(systemName: "paperclip").font(.system(size: 11))
                    }
                    if conversation.flagged {
                        Image(systemName: "flag.fill").font(.system(size: 11))
                    }
                    Text(Fmt.short(m.received))
                        .font(RT.font(11))
                }
                Text(m.subject.isEmpty ? tr("（无主题）", "(No subject)") : m.subject)
                    .font(RT.font(13, unread ? .semibold : .regular))
                    .lineLimit(2)
            }
        }
        .foregroundColor(.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(selected ? Color.shade : Color.paper)
        .overlay(alignment: .bottom) { RetroDivider(dotted: true) }
    }
}

struct FolderPickerView: View {
    let account: MailAccount
    let excluding: String
    let onPick: (MailFolder) -> Void
    @ObservedObject private var center = MailCenter.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RetroPanel(tr("移动到…", "Move to…")) {
            List {
                ForEach((center.folders[account.id] ?? []).filter { $0.selectable && $0.path != excluding }) { f in
                    Button {
                        onPick(f)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: f.role.icon).frame(width: 22)
                            Text(f.displayName).font(RT.font(15))
                            Spacer()
                        }
                        .padding(.leading, 12 + CGFloat(f.depth) * 18)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(InvertOnPressStyle())
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.paper)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .retroSheetStyle()
    }
}
