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

    func initialLoad() async {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        messages = DiskCache.loadList(account: account.id, folder: folder.path)
        await refresh()
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        let path = folder.path
        do {
            let result = try await client.perform { try await $0.fetchLatest(path, limit: 50) }
            messages = result.messages
            hasMore = result.hasMore
            DiskCache.saveList(Array(messages.prefix(100)), account: account.id, folder: path)
            if folder.role == .inbox, let top = messages.first?.uid {
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
        guard hasMore, !loadingMore, searchResults == nil, let minUID = messages.last?.uid else { return }
        loadingMore = true
        defer { loadingMore = false }
        let path = folder.path
        do {
            let result = try await client.perform { try await $0.fetchOlder(path, below: minUID, limit: 50) }
            let existing = Set(messages.map(\.uid))
            messages += result.messages.filter { !existing.contains($0.uid) }
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
            searchResults = try await client.perform { try await $0.search(path, query: q, limit: 100) }
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
    @State private var openMessage: MessageSummary?
    @State private var selecting = false
    @State private var selection = Set<Int>()
    @State private var showMove = false
    @State private var compose: ComposeRequest?

    init(account: MailAccount, folder: MailFolder) {
        self.account = account
        self.folder = folder
        _model = StateObject(wrappedValue: MessageListModel(account: account, folder: folder))
    }

    private var showRecipients: Bool { folder.role == .sent || folder.role == .drafts }

    var body: some View {
        RetroScreen(title: folder.displayName) {
            VStack(spacing: 0) {
                searchBar
                RetroDivider()
                infoBar
                RetroDivider()
                content
                if selecting { selectionBar }
            }
        }
        .retroAlert($model.error)
        .task { await model.initialLoad() }
        .navigationDestination(isPresented: Binding(get: { openMessage != nil },
                                                    set: { if !$0 { openMessage = nil } })) {
            if let m = openMessage {
                MessageDetailView(list: model, summary: m)
            }
        }
        .sheet(isPresented: $showMove) {
            FolderPickerView(account: account, excluding: folder.path) { dest in
                let uids = Array(selection)
                selection = []
                selecting = false
                Task { await model.move(uids, to: dest) }
            }
        }
        .fullScreenCover(item: $compose) { ComposeView(request: $0) }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .bold))
                TextField("搜索主题 / 发件人 / 收件人", text: $model.query)
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
            .padding(.vertical, 5)
            .overlay(Rectangle().stroke(Color.black, lineWidth: 1))

            if model.searchResults != nil || !model.query.isEmpty {
                Button("取消") { model.clearSearch() }
                    .buttonStyle(RetroButtonStyle(compact: true))
            }
            Button(selecting ? "完成" : "选择") {
                selecting.toggle()
                selection = []
            }
            .buttonStyle(RetroButtonStyle(compact: true))
            Button {
                compose = ComposeRequest(account: account)
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(RetroButtonStyle(compact: true))
        }
        .foregroundColor(.black)
        .padding(8)
    }

    private var infoBar: some View {
        let unread = center.unread[center.unreadKey(account.id, folder.path)] ?? model.messages.filter { !$0.seen }.count
        let label: String
        if let r = model.searchResults {
            label = "找到 \(r.count) 封"
        } else if selecting {
            label = "已选择 \(selection.count) 封"
        } else {
            label = "\(model.messages.count)\(model.hasMore ? "+" : "") 封邮件"
        }
        return HStack {
            Text(label)
            Spacer()
            if model.loading {
                Image(systemName: "hourglass")
            }
            Text("\(unread) 封未读")
        }
        .font(RT.font(11))
        .foregroundColor(.black)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var content: some View {
        if model.visible.isEmpty {
            VStack {
                Spacer()
                if model.loading || model.searching {
                    RetroBusy(text: "正在接收…")
                } else {
                    Text(model.searchResults != nil ? "没有找到匹配的邮件" : "此邮箱中没有邮件")
                        .font(RT.font(13))
                        .foregroundColor(.black)
                    Button("刷新") { Task { await model.refresh() } }
                        .buttonStyle(RetroButtonStyle(compact: true))
                        .padding(.top, 8)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                ForEach(model.visible) { m in
                    row(m)
                }
                if model.hasMore && model.searchResults == nil {
                    HStack {
                        Spacer()
                        RetroBusy(text: "载入更早的邮件…")
                        Spacer()
                    }
                    .padding(.vertical, 14)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.white)
                    .onAppear { Task { await model.loadMore() } }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await model.refresh() }
        }
    }

    private func row(_ m: MessageSummary) -> some View {
        let isSelected = selection.contains(m.uid)
        return MessageRow(message: m, selecting: selecting, selected: isSelected, showRecipients: showRecipients)
            .contentShape(Rectangle())
            .onTapGesture {
                if selecting {
                    if isSelected { selection.remove(m.uid) } else { selection.insert(m.uid) }
                } else {
                    openMessage = m
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.white)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    Task { await model.delete([m.uid]) }
                } label: {
                    Label("删除", systemImage: "trash")
                }
                Button {
                    Task { await model.setFlagged([m.uid], !m.flagged) }
                } label: {
                    Label(m.flagged ? "取消旗标" : "旗标", systemImage: "flag")
                }
                .tint(.gray)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    Task { await model.setSeen([m.uid], !m.seen) }
                } label: {
                    Label(m.seen ? "未读" : "已读", systemImage: m.seen ? "envelope.badge" : "envelope.open")
                }
                .tint(.black)
            }
    }

    private var selectionBar: some View {
        let uids = Array(selection)
        return VStack(spacing: 0) {
            RetroDivider()
            HStack(spacing: 6) {
                Button("全选") {
                    selection = Set(model.visible.map(\.uid))
                }
                Spacer(minLength: 0)
                Button("已读") { finish { await model.setSeen(uids, true) } }
                Button("未读") { finish { await model.setSeen(uids, false) } }
                Button("旗标") { finish { await model.setFlagged(uids, true) } }
                Button("移动") { showMove = true }.disabled(selection.isEmpty)
                Button("删除") { finish { await model.delete(uids) } }
            }
            .buttonStyle(RetroButtonStyle(compact: true))
            .padding(8)
        }
    }

    private func finish(_ op: @escaping () async -> Void) {
        guard !selection.isEmpty else { return }
        selection = []
        selecting = false
        Task { await op() }
    }
}

struct MessageRow: View {
    let message: MessageSummary
    var selecting: Bool
    var selected: Bool
    var showRecipients: Bool

    private var person: String {
        if showRecipients {
            let names = message.to.map(\.display).joined(separator: ", ")
            return names.isEmpty ? "（无收件人）" : "致：" + names
        }
        return message.from?.display ?? "（未知发件人）"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if selecting {
                ZStack {
                    Rectangle().fill(Color.white)
                    Rectangle().stroke(Color.black, lineWidth: 1)
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
                    }
                }
                .frame(width: 16, height: 16)
                .padding(.top, 2)
            }
            Text(message.seen ? " " : "◆")
                .font(RT.font(11, .bold))
                .frame(width: 10)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(person)
                        .font(RT.font(14, message.seen ? .regular : .bold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if message.answered {
                        Image(systemName: "arrowshape.turn.up.left").font(.system(size: 10))
                    }
                    if message.hasAttachment {
                        Image(systemName: "paperclip").font(.system(size: 11))
                    }
                    if message.flagged {
                        Image(systemName: "flag.fill").font(.system(size: 11))
                    }
                    Text(Fmt.short(message.date))
                        .font(RT.font(11))
                }
                Text(message.subject.isEmpty ? "（无主题）" : message.subject)
                    .font(RT.font(13))
                    .lineLimit(2)
            }
        }
        .foregroundColor(.black)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(selected ? Color(white: 0.88) : Color.white)
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
        ZStack {
            DitherBackground()
            RetroWindow(title: "移动到…", onClose: { dismiss() }) {
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
                        .listRowBackground(Color.white)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .padding(12)
        }
    }
}
