import SwiftUI
import UIKit

struct ThreadItem: Identifiable {
    let folder: String
    var summary: MessageSummary
    var parsed: ParsedMessage?
    var failed = false

    var id: String { folder + "#" + String(summary.uid) }
}

@MainActor
final class ConversationModel: ObservableObject {
    let list: MessageListModel
    @Published var items: [ThreadItem]
    @Published var expanded: Set<String> = []
    @Published var error: String?
    @Published var loadingRelated = false

    var account: MailAccount { list.account }
    var currentFolder: String { list.folder.path }

    init(list: MessageListModel, conversation: Conversation) {
        self.list = list
        let path = list.folder.path
        items = conversation.messages
            .map { ThreadItem(folder: path, summary: $0) }
            .sorted { $0.summary.received < $1.summary.received }
        if let last = items.last { expanded = [last.id] }
    }

    var subject: String {
        let s = items.last?.summary.subject ?? ""
        let core = Threading.core(s)
        return core.isEmpty ? (s.isEmpty ? tr("（无主题）", "(No subject)") : s) : core
    }

    var latestParsed: ThreadItem? {
        items.last { $0.parsed != nil }
    }

    /// 正在下载正文的邮件
    @Published private(set) var inFlight: Set<String> = []
    private var backgroundWork: Task<Void, Never>?

    /// 后台预取正文的大小上限；更大的邮件（通常带大附件）等用户点开再下载。
    private static let prefetchLimit = 400_000

    /// 先只下载并显示最新一封，其余工作（标记已读、查找关联邮件、预取旧邮件）都放到后台，不阻塞界面。
    func load() async {
        if let last = items.last { await fetch(last.id, lane: .interactive) }

        let unseen = items.filter { $0.folder == currentFolder && !$0.summary.seen }.map(\.summary.uid)
        if !unseen.isEmpty {
            for i in items.indices where unseen.contains(items[i].summary.uid) && items[i].folder == currentFolder {
                items[i].summary.set("\\Seen", true)
            }
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
        items = merged
    }

    func fetch(_ id: String, lane: MailCenter.Lane = .interactive, prefetch: Bool = false) async {
        guard let idx = items.firstIndex(where: { $0.id == id }), items[idx].parsed == nil,
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
            let parsed = await Task.detached { ParsedMessage.parse(raw) }.value
            if let i = items.firstIndex(where: { $0.id == id }) {
                items[i].parsed = parsed
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
                try await list.client.perform { try await $0.delete(path, uids: [uid], trash: trash) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// 删除/移动整个会话时只处理当前文件夹里的邮件（不动“已发送”中的回复）。
    var currentUIDs: [Int] {
        items.filter { $0.folder == currentFolder }.map(\.summary.uid)
    }

    func markLatestUnread() async {
        guard let last = items.last(where: { $0.folder == currentFolder }) else { return }
        await list.setSeen([last.summary.uid], false)
    }

    /// 给 AI 总结用的会话文本（每封只取新内容）。
    var threadText: String {
        var parts: [String] = []
        for it in items {
            guard let p = it.parsed else { continue }
            let from = p.from.first?.full ?? it.summary.from?.full ?? ""
            let date = Fmt.long(p.date ?? it.summary.received)
            let body = p.newText.isEmpty ? p.plainText : p.newText
            parts.append("From: \(from)\nDate: \(date)\nSubject: \(p.subject)\n\n\(body.prefix(4000))")
        }
        return String(parts.joined(separator: "\n\n-----\n\n").suffix(16000))
    }
}

struct ConversationView: View {
    @StateObject private var model: ConversationModel
    @EnvironmentObject private var settings: AppSettings
    let position: (index: Int, count: Int)
    let onStep: (Int) -> Void
    @State private var compose: ComposeRequest?
    @State private var preview: PreviewItem?
    @State private var fullscreen: ThreadItem?
    @State private var showMove = false
    @State private var showSummary = false
    @State private var showReply = false
    @State private var showDelete = false
    @State private var cardActionsFor: ThreadItem?
    @Environment(\.dismiss) private var dismiss

    init(list: MessageListModel, conversation: Conversation,
         position: (index: Int, count: Int) = (0, 1), onStep: @escaping (Int) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: ConversationModel(list: list, conversation: conversation))
        self.position = position
        self.onStep = onStep
    }

    private var isDraft: Bool { model.list.folder.role == .drafts }

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
                        VStack(spacing: 0) {
                            threadHeader
                            ForEach(model.items) { item in
                                card(item).id(item.id)
                            }
                        }
                        .padding(.bottom, 20)
                    }
                    .background(IOS3.cell)
                    .onAppear {
                        if model.items.count > 1, let last = model.items.last?.id {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                withAnimation { proxy.scrollTo(last, anchor: .top) }
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
        .sheet(item: $preview) { item in
            QuickLookView(url: item.url).ignoresSafeArea()
        }
        .sheet(item: $fullscreen) { item in
            RetroPanel(item.parsed?.subject ?? "") {
                if let p = item.parsed {
                    HTMLView(html: p.renderHTML(allowRemote: true)) { addr in
                        fullscreen = nil
                        compose = ComposeRequest(account: model.account, to: addr)
                    }
                    .background(Color.white)
                }
            }
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
        .sheet(isPresented: $showSummary) {
            AISummarySheet(threadText: model.threadText) { draft in
                showSummary = false
                startCompose(.replyAll, aiDraft: draft)
            }
            .preferredColorScheme(settings.colorScheme)
        }
    }

    /// 会话标题：主题 + 封数 + 参与人
    @ViewBuilder
    private var threadHeader: some View {
        if model.items.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.subject)
                    .font(RT.font(18, .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(tr("\(model.items.count) 封邮件", "\(model.items.count) messages") + participants)
                        .lineLimit(1)
                    if model.loadingRelated {
                        ProgressView().scaleEffect(0.6)
                    }
                }
                .font(RT.font(13))
                .foregroundColor(IOS3.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { RetroDivider() }
        }
    }

    private var participants: String {
        var seen = Set<String>()
        let names = model.items.compactMap { $0.summary.from?.display }.filter { seen.insert($0).inserted }
        return names.isEmpty ? "" : " · " + names.prefix(4).joined(separator: ", ")
    }

    private func card(_ item: ThreadItem) -> some View {
        MessageCard(
            item: item,
            isLatest: item.id == model.items.last?.id,
            single: model.items.count == 1,
            loading: model.inFlight.contains(item.id),
            expanded: Binding(
                get: { model.expanded.contains(item.id) },
                set: { on in
                    if on { model.expanded.insert(item.id) } else { model.expanded.remove(item.id) }
                    if on { Task { await model.fetch(item.id) } }
                }),
            folderBadge: item.folder == model.currentFolder ? nil : model.folderName(item.folder),
            onActions: { cardActionsFor = item },
            onMarkUnread: {
                Task {
                    await model.list.setSeen([item.summary.uid], false)
                    dismiss()
                }
            },
            onOpen: { att in
                do {
                    preview = PreviewItem(url: try AttachmentFiles.write(att))
                } catch {
                    model.error = error.localizedDescription
                }
            },
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
            list.append(SheetAction(tr("全屏查看", "View Full Screen")) { fullscreen = it })
            list.append(SheetAction(tr("删除这封邮件", "Delete This Message"), role: .destructive) {
                Task { await model.delete(it) }
            })
        } else {
            list.append(SheetAction(tr("AI 总结会话", "AI Recap of Thread")) { showSummary = true })
        }
        return list
    }

    private var toolbar: some View {
        IOS3Toolbar {
            ToolbarIcon(symbol: "arrow.clockwise", label: tr("刷新", "Refresh")) {
                Task { await model.list.refresh() }
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

    var body: some View {
        Text(full ? address.full : address.display)
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
    let isLatest: Bool
    let single: Bool
    let loading: Bool
    @Binding var expanded: Bool
    let folderBadge: String?
    let onActions: () -> Void
    let onMarkUnread: () -> Void
    let onOpen: (MailAttachment) -> Void
    let onMailto: (String) -> Void

    @EnvironmentObject private var settings: AppSettings
    @State private var height: CGFloat = 1
    @State private var showQuotes = false
    @State private var quoteFound = false
    @State private var allowRemote = false
    @State private var details = false

    private var sender: MailAddress? { item.parsed?.from.first ?? item.summary.from }
    private var hide: Bool { settings.hideQuotes && !showQuotes }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expanded || single {
                expandedView
            } else {
                collapsedRow
            }
            Rectangle().fill(IOS3.separator).frame(height: single ? 0 : 8)
                .overlay(alignment: .top) { RetroDivider() }
        }
        .foregroundColor(.ink)
    }

    // 折叠：和列表行一样
    private var collapsedRow: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { expanded = true }
        } label: {
            CollapsedMessageLabel(item: item, loading: loading, folderBadge: folderBadge)
        }
        .buttonStyle(InvertOnPressStyle())
    }

    @ViewBuilder
    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBlock
            RetroDivider()
            if let p = item.parsed {
                if p.hasRemoteContent && !allowRemote {
                    Button(tr("载入全部图片", "Load All Images")) { allowRemote = true }
                        .font(RT.font(14, .bold))
                        .foregroundColor(IOS3.dateBlue)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                AutoHeightHTMLView(html: p.renderHTML(allowRemote: allowRemote, hideQuotes: hide),
                                   hideQuotes: hide,
                                   height: $height,
                                   onQuoteDetected: { found in if found { quoteFound = true } },
                                   onMailto: onMailto)
                    .frame(height: max(height, 44))
                    .id((hide ? "h" : "s") + (allowRemote ? "r" : ""))
                if quoteFound || p.plainHasQuote {
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
                if !p.attachments.isEmpty { attachments(p.attachments) }
            } else if item.failed && !loading {
                Text(tr("无法载入这封邮件。", "This message couldn't be loaded."))
                    .font(RT.font(15))
                    .foregroundColor(IOS3.secondary)
                    .padding(14)
            } else {
                RetroBusy(text: tr("正在下载…", "Downloading…"))
                    .padding(14)
            }
        }
    }

    /// iPhone OS 3 邮件头：发件人/收件人气泡、主题、日期、“标为未读”。
    private var headerBlock: some View {
        let to = item.parsed?.to ?? item.summary.to
        let cc = item.parsed?.cc ?? item.summary.cc
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(tr("发件人：", "From:")).font(RT.font(14)).foregroundColor(IOS3.secondary)
                if let s = sender { AddressBubble(address: s, full: details) }
                if let badge = folderBadge {
                    Text(badge).font(RT.font(11, .bold)).foregroundColor(IOS3.secondary)
                }
                Spacer(minLength: 4)
                Button(details ? tr("隐藏", "Hide") : tr("详细信息", "Details")) { details.toggle() }
                    .font(RT.font(14, .bold))
                    .foregroundColor(IOS3.dateBlue)
                    .buttonStyle(.plain)
            }
            if details || to.count <= 2 {
                addressLine(tr("收件人：", "To:"), to)
                if !cc.isEmpty { addressLine(tr("抄送：", "Cc:"), cc) }
            } else {
                HStack(spacing: 6) {
                    Text(tr("收件人：", "To:")).font(RT.font(14)).foregroundColor(IOS3.secondary)
                    AddressBubble(address: to[0])
                    Text(tr("等 \(to.count + cc.count) 人", "and \(to.count + cc.count - 1) more"))
                        .font(RT.font(13)).foregroundColor(IOS3.secondary)
                }
            }
            RetroDivider().padding(.vertical, 2)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text((item.parsed?.subject ?? item.summary.subject).isEmpty ? tr("（无主题）", "(No Subject)") : (item.parsed?.subject ?? item.summary.subject))
                        .font(RT.font(17, .bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(Fmt.long(item.parsed?.date ?? item.summary.received))
                        .font(RT.font(13))
                        .foregroundColor(IOS3.secondary)
                    if isLatest {
                        Button(tr("标为未读", "Mark as Unread"), action: onMarkUnread)
                            .font(RT.font(13, .bold))
                            .foregroundColor(IOS3.dateBlue)
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 6)
                if !single {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { expanded = false }
                    } label: {
                        Image(systemName: "chevron.up.circle").font(.system(size: 20))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(IOS3.chevron)
                }
                Button(action: onActions) {
                    Image(systemName: "arrowshape.turn.up.left.circle").font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .foregroundColor(IOS3.value)
                .disabled(item.parsed == nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func addressLine(_ label: String, _ list: [MailAddress]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).font(RT.font(14)).foregroundColor(IOS3.secondary).padding(.top, 2)
            if list.isEmpty {
                Text("—").font(RT.font(14)).foregroundColor(IOS3.secondary)
            } else {
                FlowRow(spacing: 5) {
                    ForEach(list.indices, id: \.self) { i in
                        AddressBubble(address: list[i], full: details)
                    }
                }
            }
        }
    }

    private func attachments(_ items: [MailAttachment]) -> some View {
        VStack(spacing: 8) {
            ForEach(items) { att in
                Button {
                    onOpen(att)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: AttachmentFiles.icon(for: att.mimeType))
                            .font(.system(size: 22))
                            .foregroundColor(IOS3.value)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(att.filename).font(RT.font(14, .bold)).lineLimit(1)
                            Text(Fmt.size(att.data.count)).font(RT.font(12)).foregroundColor(IOS3.secondary)
                        }
                        Spacer()
                        Chevron()
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 48)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(IOS3.groupBorder, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(InvertOnPressStyle())
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

struct CollapsedMessageLabel: View {
    let item: ThreadItem
    let loading: Bool
    let folderBadge: String?
    @Environment(\.rowPressed) private var pressed

    var body: some View {
        let gray = pressed ? Color.white : IOS3.secondary
        HStack(alignment: .top, spacing: 0) {
            Group {
                if !item.summary.seen { UnreadDot() } else { Color.clear.frame(width: 12, height: 12) }
            }
            .frame(width: 28)
            .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.parsed?.from.first?.display ?? item.summary.from?.display ?? tr("（未知发件人）", "(Unknown Sender)"))
                        .font(RT.font(16, .bold))
                        .lineLimit(1)
                    if let b = folderBadge {
                        Text(b).font(RT.font(11, .bold)).foregroundColor(gray)
                    }
                    Spacer(minLength: 4)
                    if item.summary.hasAttachment {
                        Image(systemName: "paperclip").font(.system(size: 12)).foregroundColor(gray)
                    }
                    Text(Fmt.short(item.summary.received))
                        .font(RT.font(14))
                        .foregroundColor(pressed ? .white : IOS3.dateBlue)
                    Chevron()
                }
                Text(item.parsed?.snippet ?? item.summary.preview
                     ?? (item.failed ? tr("无法载入，点按重试", "Couldn't load — tap to retry")
                         : loading ? tr("正在下载…", "Downloading…") : tr("点按查看", "Tap to view")))
                    .font(RT.font(14))
                    .foregroundColor(gray)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.trailing, 8)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
