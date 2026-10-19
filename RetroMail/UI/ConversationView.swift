import SwiftUI
import UIKit

struct ThreadItem: Identifiable {
    let folder: String
    var summary: MessageSummary
    /// 后台算好的显示数据（解析结果、摘要、HTML 页面等）
    var display: MessageDisplay?
    var failed = false

    var parsed: ParsedMessage? { display?.parsed }
    var id: String { folder + "#" + String(summary.uid) }
}

@MainActor
final class ConversationModel: ObservableObject {
    let list: MessageListModel
    @Published var items: [ThreadItem]
    @Published var expanded: Set<String> = []
    @Published var error: String?
    @Published var loadingRelated = false
    /// 超过 4 封时，中间的旧邮件先折叠成一行
    @Published var showAll = false
    /// 正在下载正文的邮件
    @Published private(set) var inFlight: Set<String> = []
    private var backgroundWork: Task<Void, Never>?

    /// 后台预取正文的大小上限；更大的邮件（通常带大附件）等用户点开再下载。
    private static let prefetchLimit = 600_000

    var account: MailAccount { list.account }
    var currentFolder: String { list.folder.path }

    init(list: MessageListModel, conversation: Conversation) {
        self.list = list
        let path = list.folder.path
        items = conversation.messages
            .map { m -> ThreadItem in
                var x = m
                let f = x.folderPath ?? path
                x.folderPath = nil
                return ThreadItem(folder: f, summary: x)
            }
            .sorted { $0.summary.received < $1.summary.received }
        if let last = items.last { expanded = [last.id] }
    }

    var subject: String {
        let s = items.last?.summary.subject ?? ""
        let core = Threading.core(s)
        return core.isEmpty ? (s.isEmpty ? tr("（无主题）", "(No subject)") : s) : core
    }

    var latestParsed: ThreadItem? {
        items.last { $0.display != nil }
    }

    /// 自己的地址显示为“我”。
    func name(_ a: MailAddress?) -> String {
        guard let a = a else { return tr("（未知发件人）", "(Unknown Sender)") }
        return account.isMine(a.email) ? tr("我", "Me") : a.display
    }

    /// 先只下载并显示最新一封，其余工作（标记已读、查找关联邮件、预取旧邮件）都放到后台，不阻塞界面。
    func load() async {
        if let last = items.last { await fetch(last.id, lane: .interactive) }

        let unseen = items.filter { $0.folder == currentFolder && !$0.summary.seen }.map(\.summary.uid)
        if !unseen.isEmpty {
            var updated = items
            for i in updated.indices where unseen.contains(updated[i].summary.uid) && updated[i].folder == currentFolder {
                updated[i].summary.set("\\Seen", true)
            }
            items = updated
            let list = self.list
            Task { await list.setSeen(unseen, true) }
        }

        backgroundWork?.cancel()
        backgroundWork = Task { [weak self] in
            guard let self = self else { return }
            if AppSettings.shared.threaded {
                await self.loadRelated()
            }
            for id in self.items.reversed().map(\.id) {
                if Task.isCancelled { return }
                await self.fetch(id, lane: .background, prefetch: true)
            }
        }
    }

    /// 旗标：本地立即更新，再同步到服务器。
    func setFlag(_ item: ThreadItem, _ on: Bool) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i].summary.set("\\Flagged", on)
        }
        if item.folder == currentFolder {
            let list = self.list
            let uid = item.summary.uid
            Task { await list.setFlagged([uid], on) }
        } else {
            let folder = item.folder
            let uid = item.summary.uid
            let c = MailCenter.shared.client(for: account, .interactive)
            Task { _ = try? await c.perform { try await $0.store(folder, uids: [uid], flag: "\\Flagged", add: on) } }
        }
    }

    /// 离开页面时停止后台下载。
    func stop() {
        backgroundWork?.cancel()
        backgroundWork = nil
    }

    private func loadRelated() async {
        loadingRelated = true
        defer { loadingRelated = false }
        let conv = Conversation(messages: items.map(\.summary).sorted(by: MessageSummary.newestFirst))
        let found = await MailCenter.shared.relatedMessages(account, conversation: conv, currentFolder: currentFolder)
        if Task.isCancelled || found.isEmpty { return }
        var knownIds = Set(items.compactMap { $0.summary.messageId })
        var knownKeys = Set(items.map(\.id))
        var merged = items
        for (folder, m) in found {
            if let mid = m.messageId, knownIds.contains(mid) { continue }
            let item = ThreadItem(folder: folder, summary: m)
            if knownKeys.contains(item.id) { continue }
            merged.append(item)
            knownKeys.insert(item.id)
            if let mid = m.messageId { knownIds.insert(mid) }
        }
        merged.sort { $0.summary.received < $1.summary.received }
        if merged.count > 40 { merged = Array(merged.suffix(40)) }
        // 最新一封保持展开
        if let last = merged.last, !expanded.contains(last.id), merged.last?.id != items.last?.id {
            expanded.insert(last.id)
        }
        items = merged
    }

    func fetch(_ id: String, lane: MailCenter.Lane = .interactive, prefetch: Bool = false) async {
        guard let idx = items.firstIndex(where: { $0.id == id }), items[idx].display == nil,
              !inFlight.contains(id) else { return }
        let item = items[idx]
        let path = item.folder
        let uid = item.summary.uid
        let accountId = account.id
        let cached = await Task.detached { DiskCache.loadRaw(account: accountId, folder: path, uid: uid) }.value
        if prefetch && cached == nil && item.summary.size > Self.prefetchLimit { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        do {
            let raw: Data
            if let c = cached {
                raw = c
            } else {
                let client = MailCenter.shared.client(for: account, lane)
                raw = try await client.perform { try await $0.fetchRaw(path, uid: uid) }
                Task.detached { DiskCache.saveRaw(raw, account: accountId, folder: path, uid: uid) }
            }
            // 解析和所有显示计算都在后台完成，主线程只接收结果
            let display = await MessageDisplay.make(raw)
            if let i = items.firstIndex(where: { $0.id == id }) {
                items[i].display = display
                items[i].failed = false
            }
        } catch {
            if prefetch { return }
            if let i = items.firstIndex(where: { $0.id == id }) { items[i].failed = true }
            if id == items.last?.id { self.error = error.localizedDescription }
        }
    }

    func folderName(_ path: String) -> String {
        MailCenter.shared.folders[account.id]?.first { $0.path == path }?.displayName ?? path
    }

    func delete(_ item: ThreadItem) async {
        items.removeAll { $0.id == item.id }
        if item.folder == currentFolder {
            await list.delete([item.summary.uid])
        } else {
            let trash = MailCenter.shared.folder(account, role: .trash)?.path
            let path = item.folder
            let uid = item.summary.uid
            do {
                _ = try await list.client.perform { try await $0.delete(path, uids: [uid], trash: trash) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// 删除/移动整个会话时只处理当前文件夹里的邮件（不动“已发送”中的回复）。
    var currentUIDs: [Int] {
        items.filter { $0.folder == currentFolder }.map(\.summary.uid)
    }

    /// 给 AI 总结用的会话文本（每封只取新内容）。
    var threadText: String {
        var parts: [String] = []
        for it in items {
            guard let d = it.display else { continue }
            let p = d.parsed
            let from = p.from.first?.full ?? it.summary.from?.full ?? ""
            let date = Fmt.long(p.date ?? it.summary.received)
            let body = d.newText.isEmpty ? p.plainText : d.newText
            parts.append("From: \(from)\nDate: \(date)\nSubject: \(p.subject)\n\n\(body.prefix(4000))")
        }
        return String(parts.joined(separator: "\n\n-----\n\n").suffix(16000))
    }
}

/// 会话页中显示的一行：一封邮件，或“另外 N 封邮件”折叠行。
private enum ThreadRow: Identifiable {
    case item(ThreadItem)
    case more(Int)

    var id: String {
        switch self {
        case .item(let i): return i.id
        case .more: return "more"
        }
    }
}

struct ConversationView: View {
    @StateObject private var model: ConversationModel
    @EnvironmentObject private var settings: AppSettings
    let position: (index: Int, count: Int)
    let onStep: (Int) -> Void
    @State private var compose: ComposeRequest?
    @State private var fullscreen: ThreadItem?
    @State private var showMove = false
    @State private var showSummary = false
    @State private var showReply = false
    @State private var showDelete = false
    @State private var cardActionsFor: ThreadItem?
    @State private var invite: MailAttachment?
    @State private var followUp: (FollowUp, ThreadItem)?
    @ObservedObject private var followUps = FollowUpStore.shared
    @Environment(\.dismiss) private var dismiss

    init(list: MessageListModel, conversation: Conversation,
         position: (index: Int, count: Int) = (0, 1), onStep: @escaping (Int) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: ConversationModel(list: list, conversation: conversation))
        self.position = position
        self.onStep = onStep
    }

    private var isDraft: Bool { model.list.folder.role == .drafts }

    private var rows: [ThreadRow] {
        let items = model.items
        guard items.count > 4, !model.showAll else { return items.map { .item($0) } }
        return [.item(items[0]), .more(items.count - 4)] + items.suffix(3).map { .item($0) }
    }

    var body: some View {
        RetroScreen(title: tr("第 \(position.index + 1) 封，共 \(position.count) 封", "\(position.index + 1) of \(position.count)"),
                    back: model.list.folder.displayName, background: IOS3.cell) {
            HStack(spacing: 0) {
                Button { onStep(-1) } label: {
                    Image(systemName: "chevron.up").font(.system(size: 13, weight: .heavy))
                }
                .buttonStyle(BarButtonStyle())
                .disabled(position.index <= 0)
                Button { onStep(1) } label: {
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .heavy))
                }
                .buttonStyle(BarButtonStyle())
                .disabled(position.index >= position.count - 1)
            }
        } content: {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 10) {
                            threadHeader
                            ForEach(rows) { row in
                                switch row {
                                case .item(let item):
                                    card(item).id(item.id)
                                case .more(let n):
                                    moreRow(n)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                        .padding(.bottom, 24)
                    }
                    .background(PinstripeBackground())
                    .onAppear {
                        if model.items.count > 1, let last = model.items.last?.id {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                proxy.scrollTo(last, anchor: .top)
                            }
                        }
                    }
                }
                toolbar
            }
        }
        .retroAlert($model.error)
        .task { await model.load() }
        .onDisappear { model.stop() }
        .ios3ActionSheet(isPresented: $showReply, actions: replyActions(for: nil))
        .ios3ActionSheet(isPresented: Binding(get: { cardActionsFor != nil }, set: { if !$0 { cardActionsFor = nil } }),
                         actions: replyActions(for: cardActionsFor))
        .ios3ActionSheet(isPresented: $showDelete, actions: [
            SheetAction(model.items.count > 1 ? tr("删除整个会话", "Delete Conversation") : tr("删除邮件", "Delete Message"), role: .destructive) {
                let uids = model.currentUIDs
                Task {
                    await model.list.delete(uids)
                    dismiss()
                }
            },
        ])
        .fullScreenCover(item: $compose) {
            ComposeView(request: $0)
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
        }
        .fullScreenCover(item: $fullscreen) { item in
            if let d = item.display {
                FullMessageViewer(title: d.parsed.subject.isEmpty ? tr("邮件", "Message") : d.parsed.subject,
                                  page: d.page(remote: true, hideQuotes: false)) { addr in
                    fullscreen = nil
                    compose = ComposeRequest(account: model.account, to: addr)
                }
                .preferredColorScheme(settings.colorScheme)
            }
        }
        .sheet(item: $invite) { att in
            CalendarInviteView(data: att.data, account: model.account)
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
        }
        .sheet(isPresented: $showMove) {
            FolderPickerView(account: model.account, excluding: model.currentFolder) { dest in
                let uids = model.currentUIDs
                Task {
                    await model.list.move(uids, to: dest)
                    dismiss()
                }
            }
            .preferredColorScheme(settings.colorScheme)
        }
        .sheet(isPresented: Binding(get: { followUp != nil }, set: { if !$0 { followUp = nil } })) {
            if let pair = followUp {
                FollowUpEditor(item: pair.0) { on in model.setFlag(pair.1, on) }
                    .environmentObject(settings)
                    .preferredColorScheme(settings.colorScheme)
            }
        }
        .sheet(isPresented: $showSummary) {
            AISummarySheet(threadText: model.threadText) { draft in
                showSummary = false
                startCompose(.replyAll, aiDraft: draft)
            }
            .preferredColorScheme(settings.colorScheme)
        }
    }

    /// 会话标题：主题 + 封数 + 参与人 + 全部展开/折叠
    @ViewBuilder
    private var threadHeader: some View {
        if model.items.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.subject)
                    .font(RT.font(17, .bold))
                    .foregroundColor(IOS3.groupHeader)
                    .shadow(color: IOS3.groupHeaderShadow, radius: 0, x: 0, y: 1)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(tr("\(model.items.count) 封邮件", "\(model.items.count) messages") + participants)
                        .lineLimit(1)
                        .foregroundColor(IOS3.groupHeader)
                    if model.loadingRelated {
                        ProgressView().scaleEffect(0.6)
                    }
                    Spacer(minLength: 4)
                    Button(allExpanded ? tr("全部折叠", "Collapse All") : tr("全部展开", "Expand All")) {
                        withAnimation(.easeOut(duration: 0.18)) { toggleAll() }
                    }
                    .buttonStyle(RetroButtonStyle(compact: true))
                    .fixedSize()
                }
                .font(RT.font(12))
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var allExpanded: Bool {
        !model.items.isEmpty && model.items.allSatisfy { model.expanded.contains($0.id) }
    }

    private func toggleAll() {
        if allExpanded {
            // 只保留最新一封展开
            model.expanded = Set(model.items.last.map { [$0.id] } ?? [String]())
        } else {
            model.showAll = true
            for it in model.items {
                model.expanded.insert(it.id)
                Task { await model.fetch(it.id) }
            }
        }
    }

    private var participants: String {
        var seen = Set<String>()
        let names = model.items.map { model.name($0.summary.from) }.filter { seen.insert($0).inserted }
        return names.isEmpty ? "" : " · " + names.prefix(4).joined(separator: ", ")
    }

    /// “另外 N 封邮件”：叠起来的卡片样子，点按展开。
    private func moreRow(_ n: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { model.showAll = true }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(IOS3.cardBandBottom)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(IOS3.cardBorder, lineWidth: 1))
                    .padding(.horizontal, 14)
                    .offset(y: 5)
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [IOS3.cardBandTop, IOS3.cardBandBottom], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(IOS3.cardBorder, lineWidth: 1))
                    .padding(.horizontal, 6)
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack").font(.system(size: 13, weight: .semibold))
                    Text(tr("另外 \(n) 封邮件", "\(n) more messages"))
                        .font(RT.font(14, .bold))
                }
                .foregroundColor(IOS3.dateBlue)
            }
            .frame(height: 36)
            .padding(.bottom, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardBandPressStyle())
    }

    private func card(_ item: ThreadItem) -> some View {
        MessageCard(
            item: item,
            senderName: model.name(item.parsed?.from.first ?? item.summary.from),
            account: model.account,
            isLatest: item.id == model.items.last?.id,
            single: model.items.count == 1,
            isDraft: isDraft,
            loading: model.inFlight.contains(item.id),
            expanded: Binding(
                get: { model.expanded.contains(item.id) },
                set: { on in
                    if on { model.expanded.insert(item.id) } else { model.expanded.remove(item.id) }
                    if on { Task { await model.fetch(item.id) } }
                }),
            folderBadge: item.folder == model.currentFolder ? nil : model.folderName(item.folder),
            followUp: followUps.item(account: model.account.id, folder: item.folder, summary: item.summary),
            onFollowUp: { followUp = (newFollowUp(item), item) },
            onCompose: { mode in startCompose(mode, item: item) },
            onActions: { cardActionsFor = item },
            onInvite: { invite = $0 },
            onZoom: { fullscreen = item },
            onMailto: { addr in compose = ComposeRequest(account: model.account, to: addr) }
        )
    }

    private func startCompose(_ mode: ComposeRequest.Mode, item: ThreadItem? = nil, aiDraft: String? = nil) {
        guard let target = item ?? model.latestParsed, let p = target.parsed else { return }
        compose = ComposeRequest(mode: mode, account: model.account, original: p,
                                 originalFolder: target.folder, originalUID: target.summary.uid, aiDraft: aiDraft)
    }

    /// 回复动作表；item 为 nil 时针对最新一封。
    private func replyActions(for item: ThreadItem?) -> [SheetAction] {
        var list: [SheetAction] = []
        if isDraft {
            list.append(SheetAction(tr("编辑草稿", "Edit Draft")) { startCompose(.draft, item: item) })
        } else {
            list.append(SheetAction(tr("回复", "Reply")) { startCompose(.reply, item: item) })
            list.append(SheetAction(tr("全部回复", "Reply All")) { startCompose(.replyAll, item: item) })
            list.append(SheetAction(tr("转发", "Forward")) { startCompose(.forward, item: item) })
        }
        if let it = item {
            let existing = followUps.item(account: model.account.id, folder: it.folder, summary: it.summary)
            list.append(SheetAction(existing == nil ? tr("跟进…（旗标 / 提醒 / 截止 / 备注）", "Follow Up… (Flag / Remind / Due / Note)")
                                                    : tr("编辑跟进…", "Edit Follow-up…")) { openFollowUp(it) })
            let flaggedNow = existing?.flagged ?? it.summary.flagged
            list.append(SheetAction(flaggedNow ? tr("取消旗标", "Unflag") : tr("加旗标", "Flag")) { quickFlag(it, !flaggedNow) })
            list.append(SheetAction(tr("全屏查看", "View Full Screen")) { fullscreen = it })
            if it.folder == model.currentFolder {
                list.append(SheetAction(tr("标为未读", "Mark as Unread")) {
                    Task {
                        await model.list.setSeen([it.summary.uid], false)
                        dismiss()
                    }
                })
            }
            list.append(SheetAction(tr("删除这封邮件", "Delete This Message"), role: .destructive) {
                Task { await model.delete(it) }
            })
        } else {
            list.append(SheetAction(tr("AI 总结会话", "AI Recap of Thread")) { showSummary = true })
        }
        return list
    }

    private func newFollowUp(_ it: ThreadItem) -> FollowUp {
        let a = model.account
        return followUps.item(account: a.id, folder: it.folder, summary: it.summary)
            ?? FollowUp(id: FollowUp.makeId(account: a.id, folder: it.folder, summary: it.summary),
                        accountId: a.id, folder: it.folder, summary: it.summary)
    }

    private func openFollowUp(_ it: ThreadItem) {
        // 动作表收起后再弹出编辑页
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { followUp = (newFollowUp(it), it) }
    }

    private func quickFlag(_ it: ThreadItem, _ on: Bool) {
        var f = newFollowUp(it)
        f.flagged = on
        followUps.save(f)
        model.setFlag(it, on)
    }

    private var toolbar: some View {
        IOS3Toolbar {
            if MailCenter.shared.folder(model.account, role: .archive) != nil && model.list.folder.role != .archive {
                ToolbarIcon(symbol: "archivebox", label: tr("归档", "Archive")) {
                    let uids = model.currentUIDs
                    Task {
                        await model.list.archive(uids)
                        dismiss()
                    }
                }
            } else {
                ToolbarIcon(symbol: "arrow.clockwise", label: tr("刷新", "Refresh")) {
                    Task { await model.list.refresh() }
                }
            }
            ToolbarIcon(symbol: "folder", label: tr("移动", "Move")) { showMove = true }
            ToolbarIcon(symbol: "trash", label: tr("删除", "Delete")) { showDelete = true }
            ToolbarIcon(symbol: "arrowshape.turn.up.left", label: tr("回复", "Reply")) { showReply = true }
                .disabled(model.latestParsed == nil)
            ToolbarIcon(symbol: "square.and.pencil", label: tr("新邮件", "Compose")) {
                compose = ComposeRequest(account: model.account)
            }
        }
    }
}

// MARK: - 单封邮件

/// 收件人“气泡”。
struct AddressBubble: View {
    let address: MailAddress
    var full = false
    var label: String?

    var body: some View {
        Text(label ?? (full ? address.full : address.display))
            .font(RT.font(13, .bold))
            .foregroundColor(.black)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(LinearGradient(colors: [HexColor.color("#E9EFF8"), HexColor.color("#CBD8EC")], startPoint: .top, endPoint: .bottom))
            )
            .overlay(Capsule().stroke(HexColor.color("#9DB3D3"), lineWidth: 1))
            .textSelection(.enabled)
    }
}

struct MessageCard: View {
    let item: ThreadItem
    let senderName: String
    let account: MailAccount
    let isLatest: Bool
    let single: Bool
    let isDraft: Bool
    let loading: Bool
    @Binding var expanded: Bool
    let folderBadge: String?
    var followUp: FollowUp?
    var onFollowUp: (() -> Void)?
    let onCompose: (ComposeRequest.Mode) -> Void
    let onActions: () -> Void
    let onInvite: (MailAttachment) -> Void
    let onZoom: () -> Void
    let onMailto: (String) -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var height: CGFloat = 1
    @State private var shrunk = false
    @State private var showQuotes = false
    @State private var quoteFound = false
    @State private var allowRemote = false
    @State private var details = false

    private var sender: MailAddress? { item.parsed?.from.first ?? item.summary.from }
    private var hide: Bool { settings.hideQuotes && !showQuotes }
    private var open: Bool { expanded || single }
    private var mine: Bool { sender.map { account.isMine($0.email) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            band
            if open {
                expandedView
            } else {
                collapsedSnippet
            }
        }
        .foregroundColor(.ink)
        .background(IOS3.cell)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isLatest && !single ? IOS3.dateBlue.opacity(0.75) : IOS3.cardBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
    }

    private func toggle() {
        guard !single else { return }
        withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
    }

    // MARK: 标题条：点按折叠 / 展开

    private var band: some View {
        Button(action: toggle) {
            HStack(alignment: .center, spacing: 9) {
                SenderBadge(name: senderName, key: sender?.email ?? senderName, mine: mine)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        if !item.summary.seen { UnreadDot().scaleEffect(0.8) }
                        Text(senderName)
                            .font(RT.font(15, .bold))
                            .lineLimit(1)
                            .layoutPriority(1)
                        if let b = folderBadge {
                            Text(b)
                                .font(RT.font(10, .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(IOS3.pill))
                        }
                        Spacer(minLength: 4)
                        if let fu = followUp, fu.flagged {
                            Image(fu.flagColor.asset).resizable().interpolation(.high).frame(width: 15, height: 15)
                        } else if followUp == nil && item.summary.flagged {
                            Image("fu-flag").resizable().interpolation(.high).frame(width: 15, height: 15)
                        }
                        if item.summary.hasAttachment {
                            Image(systemName: "paperclip").font(.system(size: 11, weight: .semibold)).foregroundColor(IOS3.secondary)
                        }
                        Text(Fmt.compact(item.parsed?.date ?? item.summary.received))
                            .font(RT.font(12, .bold))
                            .foregroundColor(IOS3.dateBlue)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if open {
                        recipientSummary
                    }
                }
                if !single {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(IOS3.chevron)
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .frame(width: 16)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: open && !single ? [IOS3.cardBandOpenTop, IOS3.cardBandOpenBottom]
                                                       : [IOS3.cardBandTop, IOS3.cardBandBottom],
                               startPoint: .top, endPoint: .bottom)
            )
            .overlay(alignment: .top) { Rectangle().fill(IOS3.cardInnerLine).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(IOS3.cardBorder.opacity(0.6)).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(CardBandPressStyle())
        .allowsHitTesting(!single)
        .accessibilityHint(single ? "" : (open ? tr("点按折叠", "Tap to collapse") : tr("点按展开", "Tap to expand")))
    }

    private var recipientSummary: some View {
        let to = item.parsed?.to ?? item.summary.to
        let cc = item.parsed?.cc ?? item.summary.cc
        let all = to + cc
        var text = tr("发给 ", "To ")
        if let first = all.first {
            text += account.isMine(first.email) ? tr("我", "me") : first.display
            if all.count > 1 { text += tr(" 等 \(all.count) 人", " +\(all.count - 1)") }
        } else {
            text += "—"
        }
        return Text(text)
            .font(RT.font(12))
            .foregroundColor(IOS3.secondary)
            .lineLimit(1)
    }

    private var collapsedSnippet: some View {
        Button(action: toggle) {
            Text(snippet)
                .font(RT.font(13))
                .foregroundColor(IOS3.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var snippet: String {
        if let s = item.display?.snippet, !s.isEmpty { return s }
        if let p = item.summary.preview, !p.isEmpty { return p }
        if item.failed { return tr("无法载入，点按重试", "Couldn't load — tap to retry") }
        if loading { return tr("正在下载…", "Downloading…") }
        return item.summary.subject
    }

    // MARK: 展开内容

    @ViewBuilder
    private var followUpStrip: some View {
        if let fu = followUp, !fu.done, fu.deadline != nil || fu.reminder != nil || !fu.note.isEmpty {
            Button(action: onFollowUp ?? onActions) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        if let d = fu.deadline {
                            Text(tr("截止 ", "Due ") + Fmt.compact(d))
                                .font(RT.font(12, .bold))
                                .foregroundColor(d < Date() ? HexColor.color("#C0281C") : HexColor.color("#7A5A00"))
                        }
                        if let r = fu.reminder {
                            Text("⏰ " + Fmt.compact(r)).font(RT.font(12, .bold)).foregroundColor(HexColor.color("#7A5A00"))
                        }
                        Spacer(minLength: 0)
                    }
                    if !fu.note.isEmpty {
                        Text(fu.note).font(RT.font(13)).foregroundColor(HexColor.color("#5A4A00")).lineLimit(3)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HexColor.color("#FFF4A8"))
                .overlay(alignment: .bottom) { Rectangle().fill(HexColor.color("#E2CF5A")).frame(height: 1) }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            followUpStrip
            detailsBlock
            Rectangle().fill(IOS3.separator).frame(height: 1)
            if let d = item.display {
                ForEach(d.invites.indices, id: \.self) { i in
                    InviteBanner(event: d.invites[i].event) { onInvite(d.invites[i].attachment) }
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                }
                if d.hasRemote && !allowRemote {
                    Button(tr("载入全部图片", "Load All Images")) { allowRemote = true }
                        .font(RT.font(14, .bold))
                        .foregroundColor(IOS3.dateBlue)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
                if shrunk {
                    Button(action: onZoom) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.magnifyingglass")
                            Text(tr("邮件较宽，已缩小显示 · 点此放大查看", "Wide message shrunk to fit · Tap to zoom"))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .font(RT.font(13, .bold))
                        .foregroundColor(IOS3.dateBlue)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }
                    .buttonStyle(.plain)
                }
                AutoHeightHTMLView(html: d.page(remote: allowRemote, hideQuotes: hide),
                                   hideQuotes: hide,
                                   height: $height,
                                   onScaled: { z in
                                       let s = z < 0.95
                                       if s != shrunk { shrunk = s }
                                   },
                                   onQuoteDetected: { found in if found && !quoteFound { quoteFound = true } },
                                   onMailto: onMailto)
                    .frame(height: max(height, 44))
                    .id((hide ? "h" : "s") + (allowRemote ? "r" : ""))
                if quoteFound || d.plainHasQuote {
                    Button(showQuotes ? tr("隐藏引用的文字", "Hide Quoted Text") : tr("显示引用的文字", "Show Quoted Text")) {
                        showQuotes.toggle()
                        height = 1
                    }
                    .font(RT.font(14, .bold))
                    .foregroundColor(IOS3.dateBlue)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
                if !d.parsed.attachments.isEmpty {
                    AttachmentList(attachments: d.parsed.attachments, account: account)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                }
                actionStrip
            } else if item.failed && !loading {
                Button(tr("无法载入这封邮件，点按重试", "Couldn't load this message. Tap to retry.")) {
                    expanded = false
                    expanded = true
                }
                .font(RT.font(15))
                .foregroundColor(IOS3.secondary)
                .buttonStyle(.plain)
                .padding(14)
            } else {
                HStack {
                    RetroBusy(text: tr("正在下载…", "Downloading…"))
                    Spacer()
                    if item.summary.size > 0 {
                        Text(Fmt.size(item.summary.size)).font(RT.font(12)).foregroundColor(IOS3.secondary)
                    }
                }
                .padding(14)
            }
        }
    }

    /// 发件人 / 收件人 / 时间（可展开详细信息）。
    private var detailsBlock: some View {
        let to = item.parsed?.to ?? item.summary.to
        let cc = item.parsed?.cc ?? item.summary.cc
        let subject = item.parsed?.subject ?? item.summary.subject
        return VStack(alignment: .leading, spacing: 5) {
            if single {
                Text(subject.isEmpty ? tr("（无主题）", "(No Subject)") : subject)
                    .font(RT.font(17, .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if details {
                if let s = sender { addressLine(tr("发件人：", "From:"), [s]) }
                addressLine(tr("收件人：", "To:"), to)
                if !cc.isEmpty { addressLine(tr("抄送：", "Cc:"), cc) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Fmt.long(item.parsed?.date ?? item.summary.received))
                    .font(RT.font(12))
                    .foregroundColor(IOS3.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Button(details ? tr("隐藏", "Hide") : tr("详细信息", "Details")) {
                    withAnimation(.easeOut(duration: 0.15)) { details.toggle() }
                }
                .font(RT.font(13, .bold))
                .foregroundColor(IOS3.dateBlue)
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// 每封邮件底部的操作条。
    private var actionStrip: some View {
        HStack(spacing: 6) {
            if isDraft {
                stripButton(tr("编辑草稿", "Edit Draft")) { onCompose(.draft) }
            } else {
                stripButton(tr("回复", "Reply")) { onCompose(.reply) }
                stripButton(tr("全部回复", "All")) { onCompose(.replyAll) }
                stripButton(tr("转发", "Fwd")) { onCompose(.forward) }
            }
            stripButton(tr("缩放", "Zoom"), action: onZoom)
            stripButton(tr("更多", "More"), action: onActions)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(IOS3.cardStrip)
        .overlay(alignment: .top) { Rectangle().fill(IOS3.separator).frame(height: 1) }
    }

    private func stripButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RetroButtonStyle(compact: true))
    }

    private func addressLine(_ label: String, _ list: [MailAddress]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).font(RT.font(13)).foregroundColor(IOS3.secondary).padding(.top, 2)
                .fixedSize()
            if list.isEmpty {
                Text("—").font(RT.font(13)).foregroundColor(IOS3.secondary)
            } else {
                FlowRow(spacing: 5) {
                    ForEach(list.indices, id: \.self) { i in
                        AddressBubble(address: list[i], full: true)
                    }
                }
            }
        }
    }
}

/// 卡片标题条按下时略微变暗。
struct CardBandPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(Color.black.opacity(configuration.isPressed ? 0.12 : 0))
    }
}

/// 发件人首字母徽章：每个发件人一种颜色，一眼区分是谁写的。
struct SenderBadge: View {
    let name: String
    let key: String
    var mine = false

    private static let palette: [(String, String)] = [
        ("#5B8FE0", "#2C5DB4"), ("#E0895B", "#B4552C"), ("#5BBF7A", "#2C8A4B"),
        ("#B57BDB", "#7E46A8"), ("#E05B7C", "#B02C4D"), ("#4FB8C2", "#23838C"),
        ("#D9B44A", "#A6801C"), ("#8A96A8", "#596476"),
    ]

    private var initial: String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = t.first else { return "?" }
        return String(c).uppercased()
    }

    private var colors: (String, String) {
        if mine { return ("#7A8798", "#4C5868") }
        var h: UInt32 = 2166136261
        for b in key.lowercased().utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Self.palette[Int(h % UInt32(Self.palette.count))]
    }

    var body: some View {
        let c = colors
        ZStack {
            Circle().fill(LinearGradient(colors: [HexColor.color(c.0), HexColor.color(c.1)], startPoint: .top, endPoint: .bottom))
            Circle().fill(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)], startPoint: .top, endPoint: .center))
                .padding(1.5)
                .mask(Rectangle().frame(height: 15).offset(y: -7.5))
            Text(initial)
                .font(RT.font(15, .bold))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: -1)
        }
        .frame(width: 30, height: 30)
        .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 1))
    }
}

/// 旧版折叠行（保留给其他地方使用）。
struct CollapsedMessageLabel: View {
    let item: ThreadItem
    let sender: String
    let loading: Bool
    let folderBadge: String?
    @Environment(\.rowPressed) private var pressed

    private var snippet: String {
        if let s = item.display?.snippet, !s.isEmpty { return s }
        if let p = item.summary.preview, !p.isEmpty { return p }
        if item.failed { return tr("无法载入，点按重试", "Couldn't load — tap to retry") }
        if loading { return tr("正在下载…", "Downloading…") }
        return item.summary.subject
    }

    var body: some View {
        let gray = pressed ? Color.white : IOS3.secondary
        HStack(alignment: .center, spacing: 0) {
            Group {
                if !item.summary.seen { UnreadDot() } else { Color.clear.frame(width: 12, height: 12) }
            }
            .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(sender)
                        .font(RT.font(15, .bold))
                        .lineLimit(1)
                    if let b = folderBadge {
                        Text(b).font(RT.font(11, .bold)).foregroundColor(gray).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if item.summary.hasAttachment {
                        Image(systemName: "paperclip").font(.system(size: 11)).foregroundColor(gray)
                    }
                    Text(Fmt.compact(item.summary.received))
                        .font(RT.font(13))
                        .foregroundColor(pressed ? .white : IOS3.dateBlue)
                        .fixedSize()
                }
                Text(snippet)
                    .font(RT.font(13))
                    .foregroundColor(gray)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, 10)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(pressed ? Color.clear : IOS3.separator).frame(height: 1)
        }
    }
}
