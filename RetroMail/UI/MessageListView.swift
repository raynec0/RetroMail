import SwiftUI

@MainActor
final class MessageListModel: ObservableObject {
    let account: MailAccount
    let folder: MailFolder

    @Published var messages: [MessageSummary] = [] {
        didSet { regroup() }
    }
    @Published var searchResults: [MessageSummary]? {
        didSet { regroup() }
    }
    /// 分组结果缓存起来，避免每次界面刷新都重新计算。
    @Published private(set) var conversations: [Conversation] = []
    @Published var query = ""
    @Published var loading = false
    @Published var searching = false
    @Published var hasMore = false
    @Published var error: String?
    /// 服务器上这个邮箱的邮件总数
    @Published var total = 0
    @Published private(set) var loadingMore = false
    private var previewTask: Task<Void, Never>?
    private var didInitialLoad = false

    init(account: MailAccount, folder: MailFolder) {
        self.account = account
        self.folder = folder
    }

    /// 打开邮件、标记、删除等用户正在等待的操作。
    var client: IMAPClient { MailCenter.shared.client(for: account, .interactive) }
    /// 刷新列表、加载更多、搜索。
    var syncClient: IMAPClient { MailCenter.shared.client(for: account, .sync) }
    var visible: [MessageSummary] { searchResults ?? messages }

    /// 按会话分组（关闭分组时每封邮件单独一行），按最近收到时间排序。
    func regroup() {
        let list = visible.sorted(by: MessageSummary.newestFirst)
        conversations = AppSettings.shared.threaded ? Threading.group(list) : list.map { Conversation(messages: [$0]) }
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
            let (result, count) = try await syncClient.perform { c -> ((messages: [MessageSummary], hasMore: Bool), Int) in
                let r = try await c.fetchLatest(path, limit: 60)
                return (r, c.selectedExists)
            }
            messages = keepPreviews(result.messages).sorted(by: MessageSummary.newestFirst)
            hasMore = result.hasMore
            total = count
            loadPreviews()
            DiskCache.saveList(Array(messages.prefix(120)), account: account.id, folder: path)
            if folder.role == .inbox, let top = messages.map(\.uid).max() {
                BackgroundRefresh.noteSeen(account: account.id, nextUID: top + 1)
            }
            let unseen = messages.filter { !$0.seen }.count
            if !hasMore || unseen == 0 {
                MailCenter.shared.unread[MailCenter.shared.unreadKey(account.id, path)] = unseen
            } else {
                let acc = account
                Task { await MailCenter.shared.refreshUnread(acc, paths: [path]) }
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
            let result = try await syncClient.perform { try await $0.fetchOlder(path, below: minUID, limit: 60) }
            let existing = Set(messages.map(\.uid))
            messages = (messages + result.messages.filter { !existing.contains($0.uid) }).sorted(by: MessageSummary.newestFirst)
            hasMore = result.hasMore
            loadPreviews()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 刷新后保留已经取到的预览。
    private func keepPreviews(_ fresh: [MessageSummary]) -> [MessageSummary] {
        var old: [Int: String] = [:]
        for m in messages { if let p = m.preview { old[m.uid] = p } }
        return fresh.map { m in
            var x = m
            if x.preview == nil { x.preview = old[m.uid] }
            return x
        }
    }

    /// 在“列表”连接上补取正文预览（每封只取前 1.5 KB），分批更新列表。
    /// 这条连接在列表刷新后是空闲的，不会排在未读数查询后面。
    func loadPreviews() {
        guard messages.contains(where: { $0.preview == nil }) else { return }
        previewTask?.cancel()
        let path = folder.path
        let acc = account
        previewTask = Task { [weak self] in
            guard let self = self else { return }
            let missing = self.messages.filter { $0.preview == nil }
            let bg = MailCenter.shared.client(for: acc, .sync)
            for start in stride(from: 0, to: missing.count, by: 20) {
                if Task.isCancelled { return }
                let batch = Array(missing[start..<min(start + 20, missing.count)])
                guard let raw = try? await bg.perform({ try await $0.fetchPreviews(path, uids: batch.map(\.uid)) }) else { continue }
                let info = Dictionary(uniqueKeysWithValues: batch.map { ($0.uid, ($0.contentType, $0.transferEncoding)) })
                let texts = await Task.detached { () -> [Int: String] in
                    var out: [Int: String] = [:]
                    for (uid, data) in raw {
                        let meta = info[uid]
                        out[uid] = PreviewText.extract(data, contentType: meta?.0 ?? nil, transferEncoding: meta?.1 ?? nil)
                    }
                    return out
                }.value
                if Task.isCancelled { return }
                var updated = self.messages
                for i in updated.indices where updated[i].preview == nil {
                    if let t = texts[updated[i].uid] {
                        updated[i].preview = t
                    } else if batch.contains(where: { $0.uid == updated[i].uid }) {
                        updated[i].preview = ""
                    }
                }
                self.messages = updated
            }
            DiskCache.saveList(Array(self.messages.prefix(120)), account: acc.id, folder: path)
        }
    }

    func stopPreviews() {
        previewTask?.cancel()
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
            let found = try await syncClient.perform { try await $0.search(path, query: q, limit: 150) }
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
        let acc = account
        let paths = [path, dest.path]
        Task { await MailCenter.shared.refreshUnread(acc, paths: paths) }
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
    @State private var showMark = false
    @State private var compose: ComposeRequest?
    @State private var updatedAt: Date?

    init(account: MailAccount, folder: MailFolder) {
        self.account = account
        self.folder = folder
        _model = StateObject(wrappedValue: MessageListModel(account: account, folder: folder))
    }

    private var showRecipients: Bool { folder.role == .sent || folder.role == .drafts }

    private var unread: Int {
        center.unread[center.unreadKey(account.id, folder.path)] ?? model.messages.filter { !$0.seen }.count
    }

    private var title: String {
        unread > 0 ? "\(folder.displayName) (\(unread))" : folder.displayName
    }

    var body: some View {
        let convs = model.conversations
        RetroScreen(title: title, back: tr("邮箱", "Mailboxes"), background: IOS3.cell) {
            if selecting {
                Button(tr("取消", "Cancel")) {
                    selecting = false
                    selection = []
                }
                .buttonStyle(BarButtonStyle(kind: .done))
            } else {
                Button(tr("编辑", "Edit")) { selecting = true }
                    .buttonStyle(BarButtonStyle())
            }
        } content: {
            VStack(spacing: 0) {
                IOS3SearchBar(text: $model.query,
                              placeholder: tr("搜索", "Search"),
                              busy: model.searching,
                              onSubmit: { Task { await model.search() } },
                              onCancel: { model.clearSearch() })
                content(convs)
                if selecting {
                    editToolbar(convs)
                } else {
                    normalToolbar
                }
            }
        }
        .retroAlert($model.error)
        .task {
            await model.initialLoad()
            updatedAt = Date()
        }
        .onAppear { model.loadPreviews() }
        .onChange(of: settings.threaded) { _ in model.regroup() }
        .navigationDestination(isPresented: Binding(get: { openConversation != nil },
                                                    set: { if !$0 { openConversation = nil } })) {
            if let c = openConversation {
                ConversationView(list: model, conversation: c,
                                 position: position(of: c, in: convs),
                                 onStep: { step($0, from: c) })
                    .id(c.id)
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
        .ios3ActionSheet(isPresented: $showMark, actions: markActions(convs))
        .fullScreenCover(item: $compose) {
            ComposeView(request: $0)
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
        }
    }

    // MARK: 上一封 / 下一封

    private func position(of c: Conversation, in convs: [Conversation]) -> (index: Int, count: Int) {
        ((convs.firstIndex { $0.id == c.id } ?? 0), convs.count)
    }

    private func step(_ delta: Int, from c: Conversation) {
        let convs = model.conversations
        guard let i = convs.firstIndex(where: { $0.id == c.id }) else { return }
        let j = i + delta
        guard convs.indices.contains(j) else { return }
        openConversation = convs[j]
    }

    // MARK: 列表

    private func selectedUIDs(_ convs: [Conversation]) -> [Int] {
        convs.filter { selection.contains($0.id) }.flatMap(\.uids)
    }

    @ViewBuilder
    private func content(_ convs: [Conversation]) -> some View {
        if convs.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                if model.loading || model.searching {
                    RetroBusy(text: tr("正在检查邮件…", "Checking for Mail…"))
                } else {
                    Text(model.searchResults != nil ? tr("没有结果", "No Results") : tr("没有邮件", "No Mail"))
                        .font(RT.font(20, .bold))
                        .foregroundColor(IOS3.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(IOS3.cell)
        } else {
            List {
                ForEach(convs) { c in
                    row(c)
                }
                if model.searchResults == nil {
                    loadMoreRow
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(IOS3.cell)
            .environment(\.defaultMinListRowHeight, 1)
            .refreshable {
                await model.refresh()
                updatedAt = Date()
            }
        }
    }

    private func row(_ c: Conversation) -> some View {
        let isSelected = selection.contains(c.id)
        let unread = c.unread > 0
        return Button {
            if selecting {
                if isSelected { selection.remove(c.id) } else { selection.insert(c.id) }
            } else {
                openConversation = c
            }
        } label: {
            ConversationRow(conversation: c, selecting: selecting, selected: isSelected,
                            showRecipients: showRecipients, threaded: settings.threaded, myEmail: account.email)
        }
        .buttonStyle(InvertOnPressStyle())
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(IOS3.cell)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await model.delete(c.uids) }
            } label: {
                Text(tr("删除", "Delete"))
            }
            .tint(HexColor.color("#D23426"))
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                Task { await model.setSeen(c.uids, unread) }
            } label: {
                Text(unread ? tr("标为已读", "Mark Read") : tr("标为未读", "Mark Unread"))
            }
            .tint(HexColor.color("#2A63DD"))
        }
    }

    /// iPhone OS 3 列表底部的“载入更多邮件”。
    private var loadMoreRow: some View {
        Button {
            Task { await model.loadMore() }
        } label: {
            VStack(spacing: 3) {
                if model.loadingMore {
                    RetroBusy(text: tr("正在载入…", "Loading…"))
                } else if model.hasMore {
                    Text(tr("载入更多邮件", "Load More Messages"))
                        .font(RT.font(16, .bold))
                        .foregroundColor(IOS3.dateBlue)
                }
                Text(tr("共 \(max(model.total, model.messages.count)) 封邮件，\(unread) 封未读",
                        "\(max(model.total, model.messages.count)) messages total, \(unread) unread"))
                    .font(RT.font(13))
                    .foregroundColor(IOS3.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.hasMore || model.loadingMore)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(IOS3.cell)
    }

    // MARK: 工具栏

    private var normalToolbar: some View {
        IOS3Toolbar {
            ToolbarIcon(symbol: "arrow.clockwise", label: tr("刷新", "Refresh")) {
                Task {
                    await model.refresh()
                    updatedAt = Date()
                }
            }
            .frame(width: 54)
            ToolbarStatus(text: model.loading ? tr("正在检查邮件…", "Checking for Mail…") : Fmt.updated(updatedAt))
            ToolbarIcon(symbol: "square.and.pencil", label: tr("新邮件", "Compose")) {
                compose = ComposeRequest(account: account)
            }
            .frame(width: 54)
        }
    }

    private func editToolbar(_ convs: [Conversation]) -> some View {
        let uids = selectedUIDs(convs)
        let n = selection.isEmpty ? "" : " (\(selection.count))"
        return IOS3Toolbar {
            HStack(spacing: 8) {
                Button(tr("删除", "Delete") + n) { finish { await model.delete(uids) } }
                    .buttonStyle(BarButtonStyle(kind: .red))
                    .frame(maxWidth: .infinity)
                    .disabled(selection.isEmpty)
                Button(tr("移动", "Move") + n) { showMove = true }
                    .buttonStyle(BarButtonStyle())
                    .frame(maxWidth: .infinity)
                    .disabled(selection.isEmpty)
                Button(tr("标记", "Mark") + n) { showMark = true }
                    .buttonStyle(BarButtonStyle())
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 4)
        }
    }

    private func markActions(_ convs: [Conversation]) -> [SheetAction] {
        let uids = selectedUIDs(convs)
        return [
            SheetAction(tr("全选", "Select All")) { selection = Set(convs.map(\.id)) },
            SheetAction(tr("标为已读", "Mark as Read")) { finish { await model.setSeen(uids, true) } },
            SheetAction(tr("标为未读", "Mark as Unread")) { finish { await model.setSeen(uids, false) } },
            SheetAction(tr("加旗标", "Flag")) { finish { await model.setFlagged(uids, true) } },
            SheetAction(tr("取消旗标", "Unflag")) { finish { await model.setFlagged(uids, false) } },
        ]
    }

    private func finish(_ op: @escaping () async -> Void) {
        guard !selection.isEmpty else { return }
        selection = []
        selecting = false
        Task { await op() }
    }
}

/// iPhone OS 3 邮件列表的一行：蓝点、发件人、蓝色日期、主题、两行灰色预览。
struct ConversationRow: View {
    let conversation: Conversation
    var selecting: Bool
    var selected: Bool
    var showRecipients: Bool
    var threaded: Bool
    var myEmail: String = ""
    @Environment(\.rowPressed) private var pressed

    private func name(_ a: MailAddress) -> String {
        a.email.caseInsensitiveCompare(myEmail) == .orderedSame ? tr("我", "Me") : a.display
    }

    private var people: String {
        let m = conversation.latest
        if showRecipients {
            let names = m.to.map(name).joined(separator: ", ")
            return names.isEmpty ? tr("（无收件人）", "(No Recipients)") : names
        }
        if threaded && conversation.count > 1 {
            var seen = Set<String>()
            // 最近的发件人在前
            let names = conversation.messages.compactMap { $0.from.map(name) }.filter { seen.insert($0).inserted }
            return names.prefix(3).joined(separator: ", ")
        }
        return m.from.map(name) ?? tr("（未知发件人）", "(Unknown Sender)")
    }

    /// 预览：优先最新一封，没有时用会话里其他有预览的邮件
    private var previewText: String {
        if let p = conversation.latest.preview, !p.isEmpty { return p }
        return conversation.messages.compactMap { $0.preview }.first { !$0.isEmpty } ?? ""
    }

    var body: some View {
        let m = conversation.latest
        let unread = conversation.unread > 0
        let gray = pressed ? Color.white : IOS3.secondary
        HStack(alignment: .top, spacing: 0) {
            if selecting {
                ZStack {
                    if selected {
                        Circle().fill(LinearGradient(colors: [HexColor.color("#F47A6E"), HexColor.color("#C9190B")], startPoint: .top, endPoint: .bottom))
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundColor(.white)
                    } else {
                        Circle().stroke(HexColor.color("#B8B8B8"), lineWidth: 1.5)
                    }
                }
                .frame(width: 26, height: 26)
                .padding(.leading, 8)
                .padding(.top, 22)
            }
            VStack(spacing: 6) {
                if unread {
                    UnreadDot()
                } else if conversation.answered {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 10))
                        .foregroundColor(gray)
                } else {
                    Color.clear.frame(width: 12, height: 12)
                }
                if conversation.flagged {
                    Image(systemName: "flag.fill").font(.system(size: 10)).foregroundColor(pressed ? .white : HexColor.color("#E8740C"))
                }
            }
            .frame(width: 28)
            .padding(.top, 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(people)
                        .font(RT.font(17, .bold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if conversation.hasAttachment {
                        Image(systemName: "paperclip").font(.system(size: 12)).foregroundColor(gray)
                    }
                    Text(Fmt.short(m.received))
                        .font(RT.font(14))
                        .foregroundColor(pressed ? .white : IOS3.dateBlue)
                        .lineLimit(1)
                        .fixedSize()
                    Chevron()
                }
                HStack(spacing: 5) {
                    Text(m.subject.isEmpty ? tr("（无主题）", "(No Subject)") : m.subject)
                        .font(RT.font(14))
                        .lineLimit(1)
                    if threaded && conversation.count > 1 {
                        Text("\(conversation.count)")
                            .font(RT.font(12, .bold))
                            .foregroundColor(pressed ? IOS3.dateBlue : .white)
                            .padding(.horizontal, 6)
                            .background(Capsule().fill(pressed ? Color.white : IOS3.pill))
                    }
                }
                if !previewText.isEmpty {
                    Text(previewText)
                        .font(RT.font(14))
                        .foregroundColor(gray)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else if conversation.latest.preview == nil {
                    // 预览还在加载：占两行灰色细条，避免行高跳动
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(IOS3.separator).frame(height: 8)
                        Capsule().fill(IOS3.separator).frame(width: 140, height: 8)
                    }
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.trailing, 8)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(selected && !pressed ? HexColor.color("#E3EBF7") : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(pressed ? Color.clear : IOS3.separator).frame(height: 1)
        }
    }
}

/// “移动到新邮箱”页面。
struct FolderPickerView: View {
    let account: MailAccount
    let excluding: String
    let onPick: (MailFolder) -> Void
    @ObservedObject private var center = MailCenter.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            IOS3NavBar(title: tr("移到新邮箱", "Move to Mailbox")) {
                EmptyView()
            } trailing: {
                Button(tr("取消", "Cancel")) { dismiss() }
                    .buttonStyle(BarButtonStyle())
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach((center.folders[account.id] ?? []).filter { $0.selectable && $0.path != excluding }) { f in
                        Button {
                            onPick(f)
                            dismiss()
                        } label: {
                            FolderRowLabel(folder: f, count: 0)
                        }
                        .buttonStyle(InvertOnPressStyle())
                    }
                }
            }
        }
        .background(IOS3.cell.ignoresSafeArea())
        .presentationDetents([.large])
    }
}
