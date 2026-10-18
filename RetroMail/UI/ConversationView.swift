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
    @State private var compose: ComposeRequest?
    @State private var preview: PreviewItem?
    @State private var fullscreen: ThreadItem?
    @State private var showMove = false
    @State private var showSummary = false
    @Environment(\.dismiss) private var dismiss

    init(list: MessageListModel, conversation: Conversation) {
        _model = StateObject(wrappedValue: ConversationModel(list: list, conversation: conversation))
    }

    var body: some View {
        RetroScreen(title: model.subject) {
            VStack(spacing: 0) {
                header
                RetroDivider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(model.items) { item in
                                card(item).id(item.id)
                            }
                        }
                        .padding(12)
                        .padding(.bottom, 10)
                    }
                    .background(Color.mist)
                    .onAppear {
                        if let last = model.items.last?.id {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                withAnimation { proxy.scrollTo(last, anchor: .top) }
                            }
                        }
                    }
                }
                RetroDivider()
                toolbar
            }
        }
        .retroAlert($model.error)
        .task { await model.load() }
        .onDisappear { model.stop() }
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

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.subject)
                    .font(RT.font(16, .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(tr("\(model.items.count) 封邮件", "\(model.items.count) messages") + participants)
                    .font(RT.font(11))
                    .lineLimit(1)
            }
            Spacer()
            if model.loadingRelated {
                Image(systemName: "hourglass").font(.system(size: 13))
            }
        }
        .foregroundColor(.ink)
        .padding(10)
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
            loading: model.inFlight.contains(item.id),
            expanded: Binding(
                get: { model.expanded.contains(item.id) },
                set: { on in
                    if on { model.expanded.insert(item.id) } else { model.expanded.remove(item.id) }
                    if on { Task { await model.fetch(item.id) } }
                }),
            folderBadge: item.folder == model.currentFolder ? nil : model.folderName(item.folder),
            onCompose: { mode in startCompose(mode, item: item) },
            onDelete: { Task { await model.delete(item) } },
            onOpen: { att in
                do {
                    preview = PreviewItem(url: try AttachmentFiles.write(att))
                } catch {
                    model.error = error.localizedDescription
                }
            },
            onFullscreen: { fullscreen = item },
            onMailto: { addr in compose = ComposeRequest(account: model.account, to: addr) }
        )
    }

    private func startCompose(_ mode: ComposeRequest.Mode, item: ThreadItem? = nil, aiDraft: String? = nil) {
        guard let target = item ?? model.latestParsed, let p = target.parsed else { return }
        compose = ComposeRequest(mode: mode, account: model.account, original: p,
                                 originalFolder: target.folder, originalUID: target.summary.uid, aiDraft: aiDraft)
    }

    private var toolbar: some View {
        let isDraft = model.list.folder.role == .drafts
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if isDraft {
                    SpringButton(symbol: "square.and.pencil", label: tr("编辑", "Edit"), colors: .blue, size: 42) { startCompose(.draft) }
                } else {
                    SpringButton(symbol: "arrowshape.turn.up.left.fill", label: tr("回复", "Reply"), colors: .blue, size: 42) { startCompose(.reply) }
                    SpringButton(symbol: "arrowshape.turn.up.left.2.fill", label: tr("全部回复", "Reply All"), colors: .indigo, size: 42) { startCompose(.replyAll) }
                    SpringButton(symbol: "arrowshape.turn.up.right.fill", label: tr("转发", "Forward"), colors: .purple, size: 42) { startCompose(.forward) }
                }
                SpringButton(symbol: "sparkles", label: tr("AI 总结", "AI Recap"), colors: .pink, size: 42) { showSummary = true }
                SpringButton(symbol: "envelope.badge.fill", label: tr("未读", "Unread"), colors: .orange, size: 42) {
                    Task {
                        await model.markLatestUnread()
                        dismiss()
                    }
                }
                SpringButton(symbol: "folder.fill", label: tr("移动", "Move"), colors: .brown, size: 42) { showMove = true }
                SpringButton(symbol: "trash.fill", label: tr("删除", "Delete"), colors: .gray, size: 42) {
                    let uids = model.currentUIDs
                    Task {
                        await model.list.delete(uids)
                        dismiss()
                    }
                }
            }
            .padding(10)
            .padding(.trailing, 4)
        }
        .background(Color.paper)
    }
}

// MARK: - 单封邮件卡片

struct MessageCard: View {
    let item: ThreadItem
    let isLatest: Bool
    let loading: Bool
    @Binding var expanded: Bool
    let folderBadge: String?
    let onCompose: (ComposeRequest.Mode) -> Void
    let onDelete: () -> Void
    let onOpen: (MailAttachment) -> Void
    let onFullscreen: () -> Void
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
            headerRow
            if expanded {
                RetroDivider(dotted: true)
                expandedBody
            }
        }
        .background(Color.paper)
        .overlay(Rectangle().stroke(Color.ink, lineWidth: isLatest ? 2 : 1))
        .background(Rectangle().fill(Color.ink).offset(x: 3, y: 3))
        .foregroundColor(.ink)
    }

    private var headerRow: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(String((sender?.display ?? "?").prefix(1)).uppercased())
                    .font(RT.font(16, .bold))
                    .foregroundColor(.paper)
                    .frame(width: 32, height: 32)
                    .background(Color.ink)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(sender?.display ?? tr("（未知发件人）", "(Unknown sender)"))
                            .font(RT.font(14, item.summary.seen ? .semibold : .heavy))
                            .lineLimit(1)
                        if let badge = folderBadge {
                            Text(badge)
                                .font(RT.font(9, .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .overlay(Rectangle().stroke(Color.ink, lineWidth: 1))
                        }
                        Spacer(minLength: 4)
                        if item.summary.hasAttachment || !(item.parsed?.attachments.isEmpty ?? true) {
                            Image(systemName: "paperclip").font(.system(size: 11))
                        }
                        Text(Fmt.short(item.summary.received)).font(RT.font(11))
                    }
                    if expanded {
                        let to = (item.parsed?.to ?? item.summary.to).map(\.display).joined(separator: ", ")
                        Text(tr("致：", "To: ") + (to.isEmpty ? "—" : to))
                            .font(RT.font(11))
                            .lineLimit(1)
                    } else {
                        Text(item.parsed?.snippet ?? (item.failed ? tr("无法载入，点按重试", "Couldn't load — tap to retry")
                                                      : loading ? tr("正在接收…", "Receiving…") : tr("点按展开", "Tap to expand")))
                            .font(RT.font(12))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var expandedBody: some View {
        if let p = item.parsed {
            VStack(alignment: .leading, spacing: 0) {
                if details { detailLines(p) }
                HStack(spacing: 14) {
                    Button(details ? tr("▲ 隐藏详情", "▲ Hide details") : tr("▼ 详情", "▼ Details")) { details.toggle() }
                    if p.hasRemoteContent && !allowRemote {
                        Button(tr("▣ 显示远程图片", "▣ Load images")) { allowRemote = true }
                    }
                    Spacer()
                }
                .font(RT.font(11, .bold))
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                AutoHeightHTMLView(html: p.renderHTML(allowRemote: allowRemote, hideQuotes: hide),
                                   hideQuotes: hide,
                                   height: $height,
                                   onQuoteDetected: { found in if found { quoteFound = true } },
                                   onMailto: onMailto)
                    .frame(height: max(height, 44))
                    .id((hide ? "h" : "s") + (allowRemote ? "r" : ""))

                if quoteFound || p.plainHasQuote {
                    Button {
                        showQuotes.toggle()
                        height = 1
                    } label: {
                        Text(showQuotes ? tr("▲ 收起引用的内容", "▲ Hide quoted text") : tr("··· 显示引用的内容", "··· Show quoted text"))
                            .font(RT.font(11, .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .overlay(Rectangle().stroke(Color.ink, style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }

                if !p.attachments.isEmpty { attachments(p.attachments) }

                RetroDivider(dotted: true)
                HStack(spacing: 8) {
                    SpringButton(symbol: "arrowshape.turn.up.left.fill", label: tr("回复", "Reply"), colors: .blue, size: 32) { onCompose(.reply) }
                    SpringButton(symbol: "arrowshape.turn.up.left.2.fill", label: tr("全部", "All"), colors: .indigo, size: 32) { onCompose(.replyAll) }
                    SpringButton(symbol: "arrowshape.turn.up.right.fill", label: tr("转发", "Fwd"), colors: .purple, size: 32) { onCompose(.forward) }
                    SpringButton(symbol: "arrow.up.left.and.arrow.down.right", label: tr("全屏", "Full"), colors: .teal, size: 32) { onFullscreen() }
                    Spacer(minLength: 0)
                    SpringButton(symbol: "trash.fill", label: tr("删除", "Delete"), colors: .gray, size: 32) { onDelete() }
                }
                .padding(10)
            }
        } else if item.failed && !loading {
            Text(tr("无法载入这封邮件，收起后再点开可重试", "Couldn't load this message. Collapse and expand to retry."))
                .font(RT.font(12))
                .padding(12)
        } else {
            RetroBusy(text: tr("正在接收…", "Receiving…")).padding(12)
        }
    }

    private func detailLines(_ p: ParsedMessage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            line(tr("发件人", "From"), p.from.map(\.full).joined(separator: ", "))
            line(tr("收件人", "To"), p.to.map(\.full).joined(separator: ", "))
            if !p.cc.isEmpty { line(tr("抄送", "Cc"), p.cc.map(\.full).joined(separator: ", ")) }
            line(tr("日期", "Date"), Fmt.long(p.date ?? item.summary.received))
            line(tr("主题", "Subject"), p.subject)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label + tr("：", ": ")).font(RT.font(11, .bold))
            Text(value.isEmpty ? "—" : value).font(RT.font(11)).textSelection(.enabled)
        }
    }

    private func attachments(_ items: [MailAttachment]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { att in
                Button {
                    onOpen(att)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: AttachmentFiles.icon(for: att.mimeType)).frame(width: 18)
                        Text(att.filename).lineLimit(1)
                        Spacer()
                        Text(Fmt.size(att.data.count))
                    }
                    .font(RT.font(12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                }
                .buttonStyle(TileStyle(depth: 2))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}
