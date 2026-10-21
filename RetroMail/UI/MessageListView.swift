import SwiftUI

/// 智能邮箱：按条件筛选收件箱（像 Spark / Apple 邮件的“未读”“已加旗标”）。
enum SmartMailbox: String, Hashable, CaseIterable, Identifiable {
    case unread, flagged, attachments, today
    var id: String { rawValue }

    var title: String {
        switch self {
        case .unread: return tr("未读", "Unread")
        case .flagged: return tr("旗标", "Flagged")
        case .attachments: return tr("附件", "Attachments")
        case .today: return tr("今天", "Today")
        }
    }

    var icon: String {
        switch self {
        case .unread: return "mbx-mail"
        case .flagged: return "fu-flag"
        case .attachments: return "mbx-attach"
        case .today: return "mbx-calendar"
        }
    }

    var criteria: String {
        switch self {
        case .unread: return "UNSEEN"
        case .flagged: return "FLAGGED"
        case .attachments: return "OR HEADER Content-Type \"multipart/mixed\" HEADER Content-Type \"application/\""
        case .today:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "d-MMM-yyyy"
            return "SINCE " + f.string(from: Date())
        }
    }

    @MainActor
    func folder(for a: MailAccount) -> MailFolder {
        let inbox = MailCenter.shared.folder(a, role: .inbox) ?? MailFolder(path: "INBOX", delimiter: nil, flags: [])
        return inbox
    }
}

@MainActor
final class MessageListModel: ObservableObject {
    let account: MailAccount
    let folder: MailFolder
    let smart: SmartMailbox?

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
    /// 上次成功刷新的时间
    @Published var updatedAt: Date?
    private var previewTasks: [Task<Void, Never>] = []
    private var previewRequested: Set<Int> = []
    private var didInitialLoad = false

    init(account: MailAccount, folder: MailFolder, smart: SmartMailbox? = nil) {
        self.account = account
        self.folder = folder
        self.smart = smart
        Self.live.append(Weak(self))
    }

    private var cacheKey: String { smart.map { folder.path + "#smart-" + $0.rawValue } ?? folder.path }

    /// 打开邮件、标记、删除等用户正在等待的操作。
    var client: IMAPClient { MailCenter.shared.client(for: account, .interactive) }
    /// 刷新列表、加载更多、搜索。
    var syncClient: IMAPClient { MailCenter.shared.client(for: account, .sync) }
    var visible: [MessageSummary] { searchResults ?? messages }

    /// 按会话分组（关闭分组时每封邮件单独一行），按最近收到时间排序。
    /// 收件箱等文件夹会把“已发送”里你的回复并进对应的会话（只并入已有会话，不单独成行）。
    func regroup() {
        // 稍后处理（Snooze）的邮件先不显示
        let snoozed = Snooze.hidden(account: account.id, folder: folder.path)
        let shown = snoozed.isEmpty ? visible : visible.filter { !snoozed.contains($0.uid) }
        guard AppSettings.shared.threaded else {
            conversations = shown.sorted(by: MessageSummary.newestFirst).map { Conversation(messages: [$0]) }
            return
        }
        let ownIds = Set(shown.compactMap(\.messageId))
        let extras = mergesSent ? sentReplies.filter { m in m.messageId.map { !ownIds.contains($0) } ?? true } : []
        let list = (shown + extras).sorted(by: MessageSummary.newestFirst)
        conversations = Threading.group(list).filter { !$0.own.isEmpty }
    }

    /// 是否把“已发送”里的回复并入会话
    var mergesSent: Bool {
        smart == nil && searchResults == nil && ![.sent, .drafts, .trash, .junk].contains(folder.role)
    }

    /// 最近的“已发送”邮件（标记了 folderPath）
    @Published private(set) var sentReplies: [MessageSummary] = [] {
        didSet { regroup() }
    }

    private func loadSentReplies() async {
        guard mergesSent, AppSettings.shared.threaded,
              let sent = MailCenter.shared.folder(account, role: .sent) else { return }
        let path = sent.path
        func tag(_ list: [MessageSummary]) -> [MessageSummary] {
            list.map { var m = $0; m.folderPath = path; return m }
        }
        if sentReplies.isEmpty {
            let cached = DiskCache.loadList(account: account.id, folder: path)
            if !cached.isEmpty { sentReplies = tag(cached) }
        }
        let c = MailCenter.shared.client(for: account, .background)
        if let r = try? await c.perform({ try await $0.fetchLatest(path, limit: 80) }) {
            sentReplies = tag(r.messages)
            DiskCache.saveList(Array(r.messages.prefix(120)), account: account.id, folder: path)
        }
    }

    // MARK: 当前打开的列表（新邮件、移动后立即更新）

    private final class Weak { weak var model: MessageListModel?; init(_ m: MessageListModel) { model = m } }
    private static var live: [Weak] = []

    static func liveModels() -> [MessageListModel] {
        live.removeAll { $0.model == nil }
        return live.compactMap(\.model)
    }

    static func liveModel(account: UUID, folder: String) -> MessageListModel? {
        liveModels().first { $0.account.id == account && $0.folder.path == folder && $0.smart == nil }
    }

    /// 别处把邮件移进了这个文件夹：先插到列表里，等服务器确认后再刷新。
    func insertMoved(_ list: [MessageSummary]) {
        let existing = Set(messages.map(\.uid))
        let fresh = list.filter { !existing.contains($0.uid) }
        guard !fresh.isEmpty else { return }
        messages = (messages + fresh).sorted(by: MessageSummary.newestFirst)
        total += fresh.count
    }

    func initialLoad() async {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        messages = DiskCache.loadList(account: account.id, folder: cacheKey).sorted(by: MessageSummary.newestFirst)
        // 缓存里已有的邮件马上开始补预览，不用等列表刷新完
        loadPreviews()
        Task { await self.loadSentReplies() }
        await refresh()
    }

    private var refreshing = false
    private var lastSentLoad = Date.distantPast

    private var validityKey: String { "uidvalidity.\(account.id.uuidString).\(folder.path)" }

    /// 刷新：有缓存时做增量同步（只取新邮件 + 已知邮件的旗标），没有缓存或 UIDVALIDITY 变了才整页下载。
    /// 同时有好几处要求刷新时只跑一次。
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        loading = true
        defer {
            loading = false
            refreshing = false
        }
        let path = folder.path
        let known = messages.map(\.uid).filter { $0 > 0 }
        let validity = UserDefaults.standard.integer(forKey: validityKey)
        do {
            if let box = smart {
                let criteria = box.criteria
                let found = try await syncClient.perform(timeout: 60) { try await $0.searchCriteria(path, criteria: criteria, limit: 200) }
                messages = MailActions.shared.overlay(keepPreviews(found), account: account.id, folder: path).sorted(by: MessageSummary.newestFirst)
                total = messages.count
                hasMore = false
            } else if let maxUID = known.max(), validity > 0 {
                let window = Array(known.sorted().suffix(400))
                let r = try await syncClient.perform(timeout: 60) { try await $0.syncFolder(path, known: window, sinceUID: maxUID) }
                if r.uidValidity != 0 && r.uidValidity != validity {
                    try await fullRefresh(path)
                } else {
                    // 服务器没回旗标（个别服务器的怪癖）时不要把邮件当成已删除
                    let windowSet = r.flags.isEmpty && r.exists > 0 ? Set<Int>() : Set(window)
                    var list = messages.filter { m in
                        m.uid < 0 || !windowSet.contains(m.uid) || r.flags[m.uid] != nil
                    }
                    for i in list.indices {
                        if let f = r.flags[list[i].uid] { list[i].flags = f }
                    }
                    let have = Set(list.map(\.uid))
                    list += r.newMessages.filter { !have.contains($0.uid) }
                    messages = MailActions.shared.overlay(keepPreviews(list), account: account.id, folder: path)
                        .sorted(by: MessageSummary.newestFirst)
                    total = r.exists
                }
            } else {
                try await fullRefresh(path)
            }
            updatedAt = Date()
            if smart == nil, folder.role == .inbox, !BlockList.all.isEmpty, let junk = MailCenter.shared.folder(account, role: .junk) {
                let blocked = messages.filter { m in m.uid > 0 && (m.from.map { BlockList.contains($0.email) } ?? false) }
                if !blocked.isEmpty { await move(blocked.map(\.uid), to: junk, announce: false) }
            }
            ContactsStore.shared.learn(from: messages, myEmail: account.email)
            loadPreviews()
            BodyPrefetcher.prefetch(messages, account: account, folder: path)
            if mergesSent, Date().timeIntervalSince(lastSentLoad) > 300 {
                lastSentLoad = Date()
                Task { await self.loadSentReplies() }
            }
            DiskCache.saveList(Array(messages.filter { $0.uid > 0 }.prefix(150)), account: account.id, folder: cacheKey)
            if smart == nil, folder.role == .inbox, let top = messages.map(\.uid).max() {
                BackgroundRefresh.noteSeen(account: account.id, nextUID: top + 1)
            }
            let unseen = messages.filter { !$0.seen }.count
            if smart == nil, !hasMore || unseen == 0 {
                MailCenter.shared.unread[MailCenter.shared.unreadKey(account.id, path)] = unseen
            }
        } catch {
            // 自动刷新失败不打扰用户；手动刷新才提示
            if updatedAt == nil { self.error = error.localizedDescription }
        }
    }

    private func fullRefresh(_ path: String) async throws {
        let (result, count, validity) = try await syncClient.perform(timeout: 60) { c -> ((messages: [MessageSummary], hasMore: Bool), Int, Int) in
            let r = try await c.fetchLatest(path, limit: 60)
            return (r, c.selectedExists, c.selectedUIDValidity)
        }
        if validity > 0 { UserDefaults.standard.set(validity, forKey: validityKey) }
        let temps = messages.filter { $0.uid < 0 }
        messages = MailActions.shared.overlay(keepPreviews(result.messages) + temps, account: account.id, folder: path)
            .sorted(by: MessageSummary.newestFirst)
        hasMore = result.hasMore
        total = count
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

    /// 补取正文预览（每封只取前 1.5 KB）。
    /// 屏幕上最先看到的十几封走“交互”连接（已经连好、空闲），小批量先出结果；
    /// 其余的走“列表”连接在后面慢慢补。已经在取的不会重复请求，刷新列表也不会打断。
    func loadPreviews() {
        let missing = messages.filter { $0.preview == nil && !previewRequested.contains($0.uid) }
        guard !missing.isEmpty else { return }
        for m in missing { previewRequested.insert(m.uid) }
        let first = Array(missing.prefix(14))
        let rest = Array(missing.dropFirst(14))
        let acc = account
        let path = folder.path
        let fast = MailCenter.shared.client(for: acc, .interactive)
        let slow = MailCenter.shared.client(for: acc, .sync)
        previewTasks.append(Task { [weak self] in
            // 第一批只取 6 封，尽快让最上面几行出预览
            await self?.fetchPreviewBatches(first, sizes: [6, 8], client: fast, path: path)
        })
        if !rest.isEmpty {
            previewTasks.append(Task { [weak self] in
                await self?.fetchPreviewBatches(rest, sizes: [25], client: slow, path: path)
                if let self = self {
                    DiskCache.saveList(Array(self.messages.prefix(120)), account: acc.id, folder: path)
                }
            })
        }
    }

    private func fetchPreviewBatches(_ list: [MessageSummary], sizes: [Int], client: IMAPClient, path: String) async {
        var start = 0
        var round = 0
        while start < list.count {
            if Task.isCancelled { break }
            let size = sizes[min(round, sizes.count - 1)]
            let batch = Array(list[start..<min(start + size, list.count)])
            start += size
            round += 1
            guard let raw = try? await client.perform({ try await $0.fetchPreviews(path, uids: batch.map(\.uid)) }) else {
                // 失败的留给下次（重新进入或刷新时再取）
                for m in batch { previewRequested.remove(m.uid) }
                continue
            }
            let info = Dictionary(batch.map { ($0.uid, ($0.contentType, $0.transferEncoding)) }, uniquingKeysWith: { a, _ in a })
            let texts = await Task.detached { () -> [Int: String] in
                var out: [Int: String] = [:]
                for (uid, data) in raw {
                    let meta = info[uid]
                    out[uid] = PreviewText.extract(data, contentType: meta?.0 ?? nil, transferEncoding: meta?.1 ?? nil)
                }
                return out
            }.value
            applyPreviews(texts, batch: Set(batch.map(\.uid)))
        }
        if !Task.isCancelled {
            DiskCache.saveList(Array(messages.prefix(120)), account: account.id, folder: path)
        }
    }

    private func applyPreviews(_ texts: [Int: String], batch: Set<Int>) {
        var updated = messages
        var changed = false
        for i in updated.indices where updated[i].preview == nil && batch.contains(updated[i].uid) {
            updated[i].preview = texts[updated[i].uid] ?? ""
            changed = true
        }
        if changed { messages = updated }
        if var r = searchResults {
            var rc = false
            for i in r.indices where r[i].preview == nil && batch.contains(r[i].uid) {
                r[i].preview = texts[r[i].uid] ?? ""
                rc = true
            }
            if rc { searchResults = r }
        }
    }

    func stopPreviews() {
        previewTasks.forEach { $0.cancel() }
        previewTasks = []
        previewRequested = []
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
        MailActions.shared.enqueue(PendingAction(account: account.id, folder: folder.path, uids: uids, kind: .flag, flag: "\\Seen", on: on))
        MailCenter.shared.updateBadge()
    }

    func setFlagged(_ uids: [Int], _ on: Bool) async {
        update(uids) { $0.set("\\Flagged", on) }
        MailActions.shared.enqueue(PendingAction(account: account.id, folder: folder.path, uids: uids, kind: .flag, flag: "\\Flagged", on: on))
    }

    func delete(_ uids: [Int]) async {
        let removed = visible.filter { uids.contains($0.uid) }
        let unseenRemoved = removed.filter { !$0.seen }.count
        remove(uids)
        MailCenter.shared.adjustUnread(account, folder.path, by: -unseenRemoved)
        let trash = MailCenter.shared.folder(account, role: .trash)?.path
        let toTrash = trash != nil && trash != folder.path
        let id = MailActions.shared.enqueue(PendingAction(account: account.id, folder: folder.path, uids: uids, kind: .delete,
                                                          dest: toTrash ? trash : nil, messages: removed))
        if toTrash, let t = trash { insertTemps(removed, into: t) }
        let n = removed.count
        MailCenter.shared.showToast(MailToast(text: tr("已删除 \(n) 封邮件", "Deleted \(n) message\(n == 1 ? "" : "s")"),
                                              undo: toTrash ? { _ = MailActions.shared.undo(id) } : nil))
        DiskCache.saveList(Array(messages.filter { $0.uid > 0 }.prefix(150)), account: account.id, folder: folder.path)
        MailCenter.shared.updateBadge()
    }

    /// 移动：本机立即生效（这里消失、目标文件夹里立刻出现），服务器在后台同步。
    func move(_ uids: [Int], to dest: MailFolder, announce: Bool = true) async {
        let moved = visible.filter { uids.contains($0.uid) }
        let unseen = moved.filter { !$0.seen }.count
        remove(uids)
        MailCenter.shared.adjustUnread(account, folder.path, by: -unseen)
        MailCenter.shared.adjustUnread(account, dest.path, by: unseen)
        let id = MailActions.shared.enqueue(PendingAction(account: account.id, folder: folder.path, uids: uids, kind: .move,
                                                          dest: dest.path, messages: moved))
        insertTemps(moved, into: dest.path)
        DiskCache.saveList(Array(messages.filter { $0.uid > 0 }.prefix(150)), account: account.id, folder: folder.path)
        if announce {
            MailCenter.shared.showToast(MailToast(text: tr("已移到“\(dest.displayName)”", "Moved to \(dest.displayName)"),
                                                  undo: { _ = MailActions.shared.undo(id) }))
        }
        MailCenter.shared.updateBadge()
    }

    /// 在目标文件夹里先放上临时条目（UID 记为负数），同步完成后换成真正的。
    private func insertTemps(_ list: [MessageSummary], into path: String) {
        guard let target = MessageListModel.liveModel(account: account.id, folder: path) else { return }
        let temps = list.map { m -> MessageSummary in
            var x = m
            x.uid = -m.uid
            x.folderPath = nil
            return x
        }
        target.insertMoved(temps)
    }

    func removeLocally(_ uids: Set<Int>) {
        guard !uids.isEmpty else { return }
        messages.removeAll { uids.contains($0.uid) }
        searchResults?.removeAll { uids.contains($0.uid) }
    }

    /// 归档：移到“归档”文件夹（没有时提示）。
    func archive(_ uids: [Int]) async {
        guard let dest = MailCenter.shared.folder(account, role: .archive) else {
            error = tr("没有找到“归档”文件夹。可以在首页“编辑”里新建一个名为“归档”或 Archive 的邮箱。",
                       "No Archive folder was found. Create one named “Archive” from Edit on the home screen.")
            return
        }
        await move(uids, to: dest)
    }
}

struct MessageListView: View {
    let account: MailAccount
    let folder: MailFolder
    @StateObject private var model: MessageListModel
    @ObservedObject private var center = MailCenter.shared
    @ObservedObject private var followUps = FollowUpStore.shared
    @EnvironmentObject private var settings: AppSettings
    @State private var openConversation: Conversation?
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var showMove = false
    @State private var showMark = false
    @State private var compose: ComposeRequest?
    @State private var updatedAt: Date?

    let smart: SmartMailbox?

    init(account: MailAccount, folder: MailFolder, smart: SmartMailbox? = nil) {
        self.account = account
        self.folder = folder
        self.smart = smart
        _model = StateObject(wrappedValue: MessageListModel(account: account, folder: folder, smart: smart))
    }

    private var showRecipients: Bool { folder.role == .sent || folder.role == .drafts }
    private var hasArchive: Bool {
        folder.role != .archive && center.folder(account, role: .archive) != nil
    }

    private var unread: Int {
        center.unread[center.unreadKey(account.id, folder.path)] ?? model.messages.filter { !$0.seen }.count
    }

    private var title: String {
        if let s = smart { return s.title + (model.messages.isEmpty ? "" : " (\(model.messages.count))") }
        return unread > 0 ? "\(folder.displayName) (\(unread))" : folder.displayName
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
                            showRecipients: showRecipients, threaded: settings.threaded, myEmail: account.email,
                            followUp: followUps.item(account: account.id, folder: model.folder.path, summary: c.ownLatest))
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
            if hasArchive {
                Button {
                    Task { await model.archive(c.uids) }
                } label: {
                    Text(tr("归档", "Archive"))
                }
                .tint(HexColor.color("#5B8F3A"))
            }
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
            ToolbarStatus(text: model.loading ? tr("正在检查邮件…", "Checking for Mail…") : Fmt.updated(model.updatedAt ?? updatedAt))
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
                if hasArchive {
                    Button(tr("归档", "Archive")) { finish { await model.archive(uids) } }
                        .buttonStyle(BarButtonStyle())
                        .frame(maxWidth: .infinity)
                        .disabled(selection.isEmpty)
                }
                Button(tr("移动", "Move")) { showMove = true }
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
    var followUp: FollowUp? = nil
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
                } else if conversation.answered || conversation.includesMyReplies {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 10))
                        .foregroundColor(gray)
                } else {
                    Color.clear.frame(width: 12, height: 12)
                }
                if let fu = followUp, !fu.done {
                    if fu.flagged {
                        Image(fu.flagColor.asset).resizable().interpolation(.high).frame(width: 14, height: 14)
                    }
                    if fu.isOverdue {
                        Text("!").font(RT.font(13, .bold)).foregroundColor(HexColor.color("#C0281C"))
                    } else if fu.deadline != nil || fu.reminder != nil {
                        Image("fu-clock").resizable().interpolation(.high).frame(width: 13, height: 13)
                    }
                } else if conversation.flagged {
                    Image("fu-flag").resizable().interpolation(.high).frame(width: 14, height: 14)
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
