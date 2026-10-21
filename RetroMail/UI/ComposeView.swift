import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct ComposeRequest: Identifiable {
    enum Mode { case new, reply, replyAll, forward, draft }

    let id = UUID()
    var mode: Mode = .new
    var account: MailAccount?
    var to: String = ""
    var original: ParsedMessage?
    var originalFolder: String?
    var originalUID: Int?
    /// AI 预先起草的正文（纯文本）
    var aiDraft: String?

    var originalRef: (folder: String, uid: Int)? {
        guard let f = originalFolder, let u = originalUID else { return nil }
        return (f, u)
    }
}

struct RibbonSheet {
    let title: String
    let actions: [SheetAction]
}

struct ComposeView: View {
    let request: ComposeRequest
    @FocusState private var focusedField: String?
    @ObservedObject private var store = AccountStore.shared
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ed = EditorController()

    @State private var accountId: UUID?
    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var subject = ""
    @State private var showCc = false
    @State private var fieldsExpanded = true
    @State private var attachments: [OutgoingAttachment] = []
    @State private var priority: MailPriority = .normal
    @State private var readReceipt = false

    @State private var sheet: EditorSheet?
    @State private var attachPhotos: [PhotosPickerItem] = []
    @State private var inlinePhotos: [PhotosPickerItem] = []
    @State private var showAttachPhotos = false
    @State private var showInlinePhotos = false
    @State private var showFiles = false

    @State private var busy: String?
    @State private var error: String?
    @State private var confirmClose = false
    @State private var ribbonSheet: RibbonSheet?
    @State private var lastSignatureAccount: UUID?
    @State private var prepared = false

    private var account: MailAccount? {
        store.accounts.first { $0.id == accountId } ?? store.accounts.first
    }

    private var windowTitle: String {
        switch request.mode {
        case .new: return tr("新邮件", "New Message")
        case .reply, .replyAll: return tr("回复", "Reply")
        case .forward: return tr("转发", "Forward")
        case .draft: return tr("编辑草稿", "Edit Draft")
        }
    }

    private var isDirty: Bool {
        ed.dirty || !to.isEmpty || !cc.isEmpty || !subject.isEmpty || !attachments.isEmpty
    }

    /// 给 AI 用的原邮件上下文。
    private var aiContext: String {
        guard let o = request.original else { return "" }
        let from = o.from.first?.full ?? ""
        let date = o.date.map { Fmt.long($0) } ?? ""
        return String("From: \(from)\nDate: \(date)\nSubject: \(o.subject)\n\n\(o.plainText)".prefix(12000))
    }

    var body: some View {
        VStack(spacing: 0) {
            IOS3NavBar(title: windowTitle) {
                Button(tr("取消", "Cancel")) { if isDirty { confirmClose = true } else { dismiss() } }
                    .buttonStyle(BarButtonStyle())
            } trailing: {
                Button(tr("发送", "Send"), action: send)
                    .buttonStyle(BarButtonStyle(kind: .done))
            }
            if ed.focused && !fieldsExpanded {
                collapsedFields
            } else {
                fields
            }
            if !attachments.isEmpty { attachmentStrip }
            RetroDivider()
            RichEditorView(controller: ed, placeholder: tr("在此输入正文…", "Write your message…"))
            FormatRibbon(ed: ed, sheet: $sheet, priority: $priority, readReceipt: $readReceipt,
                         onInlineImage: { showInlinePhotos = true },
                         onAttachPhoto: { showAttachPhotos = true },
                         onAttachFile: { showFiles = true },
                         onSignature: insertSignature,
                         onSaveDraft: { saveDraft(thenClose: true) },
                         onSend: send,
                         onActionSheet: { title, actions in ribbonSheet = RibbonSheet(title: title, actions: actions) })
        }
        .foregroundColor(.ink)
        .background(IOS3.cell.ignoresSafeArea())
        .busyOverlay(busy != nil, busy ?? "")
        .retroAlert($error)
        .sheetHost()
        .onChange(of: accountId) { accountChanged($0) }
        .onChange(of: ed.focused) { f in
            if f { fieldsExpanded = false }
        }
        .sheet(item: $sheet) { s in
            EditorSheetView(sheet: s, ed: ed, aiContext: aiContext) { subject = $0 }
                .preferredColorScheme(settings.colorScheme)
        }
        .ios3ActionSheet(isPresented: Binding(get: { ribbonSheet != nil }, set: { if !$0 { ribbonSheet = nil } }),
                         title: ribbonSheet?.title, actions: ribbonSheet?.actions ?? [])
        .ios3ActionSheet(isPresented: $confirmClose, actions: [
            SheetAction(tr("删除草稿", "Delete Draft"), role: .destructive) { dismiss() },
            SheetAction(tr("存储草稿", "Save Draft")) { saveDraft(thenClose: true) },
        ])
        .photosPicker(isPresented: $showAttachPhotos, selection: $attachPhotos, maxSelectionCount: 10,
                      matching: .any(of: [.images, .videos]))
        .photosPicker(isPresented: $showInlinePhotos, selection: $inlinePhotos, maxSelectionCount: 5, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .onChange(of: attachPhotos) { items in
            guard !items.isEmpty else { return }
            Task { await loadAttachmentPhotos(items) }
        }
        .onChange(of: inlinePhotos) { items in
            guard !items.isEmpty else { return }
            Task { await loadInlinePhotos(items) }
        }
        .onAppear(perform: prepare)
    }

    // MARK: 收件人等字段

    /// iPhone OS 3 写信页的一行：灰色标签 + 输入框，下面一条分隔线。
    private func fieldRow(_ label: String, _ text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(RT.font(15))
                .foregroundColor(IOS3.secondary)
                .lineLimit(1)
                .fixedSize()
            TextField("", text: text)
                .font(RT.font(15))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 42)
        .overlay(alignment: .bottom) { RetroDivider() }
    }

    /// 收件人输入行：边输边从常用联系人里补全。
    @ViewBuilder
    private func recipientRow(_ label: String, _ text: Binding<String>, key: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(label)
                    .font(RT.font(15))
                    .foregroundColor(IOS3.secondary)
                    .lineLimit(1)
                    .fixedSize()
                TextField("", text: text)
                    .font(RT.font(15))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .focused($focusedField, equals: key)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 42)
            .overlay(alignment: .bottom) { RetroDivider() }
            if focusedField == key {
                let token = Self.lastToken(text.wrappedValue)
                let used = Set(MailAddress.parseInput(text.wrappedValue).map { $0.email.lowercased() })
                let hits = token.count >= 1 ? ContactsStore.shared.suggest(token, excluding: used) : []
                ForEach(hits, id: \.email) { e in
                    Button {
                        text.wrappedValue = Self.replaceLastToken(text.wrappedValue, with: e.name.isEmpty ? e.email : "\(e.name) <\(e.email)>")
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        HStack(spacing: 8) {
                            SenderBadge(name: e.name.isEmpty ? e.email : e.name, key: e.email)
                                .scaleEffect(0.8)
                                .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(e.name.isEmpty ? e.email : e.name).font(RT.font(15, .bold)).lineLimit(1)
                                if !e.name.isEmpty {
                                    Text(e.email).font(RT.font(12)).foregroundColor(IOS3.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 46)
                        .background(IOS3.cellBottom)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(InvertOnPressStyle())
                    .overlay(alignment: .bottom) { RetroDivider() }
                }
            }
        }
    }

    static func lastToken(_ s: String) -> String {
        let parts = s.components(separatedBy: CharacterSet(charactersIn: ",;，；"))
        return (parts.last ?? "").trimmingCharacters(in: .whitespaces)
    }

    static func replaceLastToken(_ s: String, with v: String) -> String {
        var parts = s.components(separatedBy: CharacterSet(charactersIn: ",;，；")).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty { parts = [""] }
        parts[parts.count - 1] = v
        return parts.filter { !$0.isEmpty }.joined(separator: ", ") + ", "
    }

    @ViewBuilder
    private var fields: some View {
        VStack(spacing: 0) {
            recipientRow(tr("收件人：", "To:"), $to, key: "to")
            if showCc {
                recipientRow(tr("抄送：", "Cc:"), $cc, key: "cc")
                recipientRow(tr("密送：", "Bcc:"), $bcc, key: "bcc")
            } else {
                Button {
                    showCc = true
                } label: {
                    HStack(spacing: 6) {
                        Text(tr("抄送/密送：", "Cc/Bcc:")).font(RT.font(15)).foregroundColor(IOS3.secondary)
                        if store.accounts.count > 1 {
                            Text(tr("发件人：", "From:") + " " + (account?.email ?? ""))
                                .font(RT.font(15)).foregroundColor(IOS3.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) { RetroDivider() }
            }
            if showCc && store.accounts.count > 1 {
                Menu {
                    ForEach(store.accounts) { a in
                        Button(a.title) { accountId = a.id }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(tr("发件人：", "From:")).font(RT.font(15)).foregroundColor(IOS3.secondary)
                        Text(account?.title ?? "").font(RT.font(15)).foregroundColor(.ink).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundColor(IOS3.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 42)
                }
                .overlay(alignment: .bottom) { RetroDivider() }
            }
            HStack(spacing: 0) {
                fieldRow(tr("主题：", "Subject:"), $subject)
                if priority != .normal || readReceipt {
                    HStack(spacing: 4) {
                        if priority == .high { Image(systemName: "exclamationmark").foregroundColor(.red) }
                        if priority == .low { Image(systemName: "arrow.down").foregroundColor(IOS3.value) }
                        if readReceipt { Image(systemName: "checkmark.seal").foregroundColor(IOS3.value) }
                    }
                    .font(.system(size: 13, weight: .bold))
                    .padding(.trailing, 10)
                    .frame(minHeight: 42)
                    .overlay(alignment: .bottom) { RetroDivider() }
                }
            }
        }
    }

    private var collapsedFields: some View {
        Button {
            fieldsExpanded = true
        } label: {
            HStack(spacing: 6) {
                Text(tr("收件人：", "To:")).foregroundColor(IOS3.secondary)
                Text(to.isEmpty ? "—" : to).lineLimit(1)
                Text("·").foregroundColor(IOS3.secondary)
                Text(subject.isEmpty ? tr("（无主题）", "(No Subject)") : subject).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).foregroundColor(IOS3.chevron)
            }
            .font(RT.font(14))
            .padding(.horizontal, 10)
            .frame(minHeight: 38)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { RetroDivider() }
        }
        .buttonStyle(.plain)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                        Text(a.filename).lineLimit(1).frame(maxWidth: 150)
                        Text(Fmt.size(a.data.count)).opacity(0.7)
                        Button {
                            attachments.removeAll { $0.id == a.id }
                        } label: {
                            Image(systemName: "xmark.square")
                        }
                        .buttonStyle(.plain)
                    }
                    .font(RT.font(12, .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(LinearGradient(colors: [HexColor.color("#E9EFF8"), HexColor.color("#CBD8EC")], startPoint: .top, endPoint: .bottom)))
                    .overlay(Capsule().stroke(HexColor.color("#9DB3D3"), lineWidth: 1))
                }
                Text(tr("共 \(Fmt.size(attachments.reduce(0) { $0 + $1.data.count }))", "Total \(Fmt.size(attachments.reduce(0) { $0 + $1.data.count }))"))
                    .font(RT.font(12))
                    .foregroundColor(IOS3.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    // MARK: 预填内容

    /// 带外层容器的签名 HTML（容器 class="re-sig"，切换发件账户时可以整体替换）。
    private func signatureHTML(_ a: MailAccount?) -> String {
        guard let body = a?.signatureBodyHTML, !body.isEmpty else { return "" }
        return "<div class=\"re-sig\"><div><br></div>" + body + "</div>"
    }

    /// 按“新邮件 / 回复转发”的设置决定是否自动加签名。
    private func autoSignature(_ a: MailAccount?) -> String {
        guard let a = a else { return "" }
        switch request.mode {
        case .new: return a.signatureOnNew == false ? "" : signatureHTML(a)
        case .reply, .replyAll, .forward: return a.signatureOnReply == false ? "" : signatureHTML(a)
        case .draft: return ""
        }
    }

    private func quoteHeader(_ o: ParsedMessage, forward: Bool) -> String {
        func row(_ k: String, _ v: String) -> String {
            v.isEmpty ? "" : "<b>\(k)</b> \(HTMLText.escape(v))<br>"
        }
        var h = "<div style=\"border:none;border-top:solid #E1E1E1 1.0pt;padding:3.0pt 0 0 0\"><p style=\"margin:0;font-size:10.5pt\">"
        if forward { h += "<b>\(tr("---------- 转发的邮件 ----------", "---------- Forwarded message ----------"))</b><br>" }
        h += row(tr("发件人:", "From:"), o.from.map(\.full).joined(separator: ", "))
        h += row(tr("发送时间:", "Sent:"), o.date.map { Fmt.long($0) } ?? "")
        h += row(tr("收件人:", "To:"), o.to.map(\.full).joined(separator: ", "))
        h += row(tr("抄送:", "Cc:"), o.cc.map(\.full).joined(separator: ", "))
        h += row(tr("主题:", "Subject:"), o.subject)
        h += "</p></div><div><br></div>"
        return h
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        // 直接用本地变量：刚写入的 @State 在同一次调用里不一定能读到新值
        let acct = request.account.flatMap { r in store.accounts.first { $0.id == r.id } } ?? store.accounts.first
        accountId = acct?.id
        lastSignatureAccount = acct?.id
        to = request.to
        let sig = autoSignature(acct)
        let draft = request.aiDraft.map { AIText.toHTML($0) } ?? ""

        guard let o = request.original else {
            ed.setInitialHTML(draft.isEmpty ? (sig.isEmpty ? "" : "<div><br></div>" + sig) : draft + sig)
            return
        }
        let me = acct?.email ?? ""

        switch request.mode {
        case .reply, .replyAll:
            let primary = o.replyTo.isEmpty ? o.from : o.replyTo
            var toList = primary
            var ccList: [MailAddress] = []
            if request.mode == .replyAll {
                toList += o.to
                ccList = o.cc
            }
            toList = unique(toList.filter { $0.email.caseInsensitiveCompare(me) != .orderedSame })
            if toList.isEmpty { toList = primary }
            ccList = unique(ccList.filter { $0.email.caseInsensitiveCompare(me) != .orderedSame && !toList.contains($0) })
            to = toList.map(\.full).joined(separator: ", ")
            cc = ccList.map(\.full).joined(separator: ", ")
            showCc = !cc.isEmpty
            subject = prefixed("Re: ", o.subject)
            let top = draft.isEmpty ? "<div><br></div>" : draft
            ed.setInitialHTML(top + sig + "<div class=\"re-quote\"><div><br></div>" + quoteHeader(o, forward: false) + o.quotableHTML + "</div>")
        case .forward:
            subject = prefixed("Fwd: ", o.subject)
            attachments = o.attachments.map { OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
            ed.setInitialHTML("<div><br></div>" + draft + sig + "<div class=\"re-quote\"><div><br></div>" + quoteHeader(o, forward: true) + o.quotableHTML + "</div>")
        case .draft:
            to = o.to.map(\.full).joined(separator: ", ")
            cc = o.cc.map(\.full).joined(separator: ", ")
            showCc = !cc.isEmpty
            subject = o.subject
            attachments = o.attachments.map { OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
            ed.setInitialHTML(o.quotableHTML)
        case .new:
            ed.setInitialHTML(draft + sig)
        }
    }

    private func insertSignature() {
        guard let body = account?.signatureBodyHTML, !body.isEmpty else {
            error = tr("还没有设置签名。请到“设置 > 账户 > 签名”里编辑。", "No signature yet. Edit it in Settings > Account > Signature.")
            return
        }
        ed.call("setSignature", body)
    }

    /// 换了发件账户：把正文里的签名换成新账户的。
    private func accountChanged(_ id: UUID?) {
        guard prepared, id != lastSignatureAccount else { return }
        lastSignatureAccount = id
        let a = store.accounts.first { $0.id == id }
        let body = autoSignature(a).isEmpty ? "" : (a?.signatureBodyHTML ?? "")
        ed.call("setSignature", body)
    }

    private func unique(_ list: [MailAddress]) -> [MailAddress] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.email.lowercased()).inserted }
    }

    private func prefixed(_ prefix: String, _ s: String) -> String {
        let l = s.lowercased()
        if prefix == "Re: " && (l.hasPrefix("re:") || l.hasPrefix("回复") || l.hasPrefix("答复")) { return s }
        if prefix == "Fwd: " && (l.hasPrefix("fwd:") || l.hasPrefix("fw:") || l.hasPrefix("转发")) { return s }
        return prefix + s
    }

    // MARK: 图片与附件

    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let name = url.lastPathComponent
                    attachments.append(OutgoingAttachment(filename: name,
                                                          mimeType: OutgoingAttachment.mimeType(forFilename: name),
                                                          data: data))
                } catch {
                    self.error = tr("无法读取文件：", "Couldn't read the file: ") + error.localizedDescription
                }
            }
        case .failure(let e):
            error = e.localizedDescription
        }
    }

    private func loadAttachmentPhotos(_ items: [PhotosPickerItem]) async {
        let stamp = Int(Date().timeIntervalSince1970)
        for (n, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            if let t = type, t.conforms(to: .heic) || t.conforms(to: .heif),
               let img = UIImage(data: data), let jpg = img.jpegData(compressionQuality: 0.85) {
                attachments.append(OutgoingAttachment(filename: "IMG_\(stamp)_\(n + 1).jpg", mimeType: "image/jpeg", data: jpg))
            } else {
                let ext = type?.preferredFilenameExtension ?? "jpg"
                let mime = type?.preferredMIMEType ?? "application/octet-stream"
                attachments.append(OutgoingAttachment(filename: "IMG_\(stamp)_\(n + 1).\(ext)", mimeType: mime, data: data))
            }
        }
        attachPhotos = []
    }

    /// 正文内嵌图片：缩到最长边 1600 像素，转 JPEG（PNG 透明图保留 PNG）。
    private func loadInlinePhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else { continue }
            let scaled = Self.downscale(img, maxSide: 1600)
            let isPNG = item.supportedContentTypes.first?.conforms(to: .png) ?? false
            let out: Data?
            let mime: String
            if isPNG, let png = scaled.pngData(), png.count < 1_500_000 {
                out = png
                mime = "image/png"
            } else {
                out = scaled.jpegData(compressionQuality: 0.82)
                mime = "image/jpeg"
            }
            if let d = out {
                ed.act("image", "data:\(mime);base64,\(d.base64EncodedString())")
            }
        }
        inlinePhotos = []
    }

    static func downscale(_ img: UIImage, maxSide: CGFloat) -> UIImage {
        let w = img.size.width * img.scale
        let h = img.size.height * img.scale
        let longest = max(w, h)
        guard longest > maxSide else { return img }
        let ratio = maxSide / longest
        let size = CGSize(width: floor(w * ratio), height: floor(h * ratio))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: 发送 / 草稿

    private func buildMail(_ a: MailAccount, html: String, text: String) -> OutgoingMail {
        let o = request.original
        var refs: String?
        if request.mode != .new && request.mode != .draft, let mid = o?.messageId {
            refs = [o?.references, mid].compactMap { $0 }.joined(separator: " ")
        }
        let isReply = request.mode == .reply || request.mode == .replyAll
        var mail = OutgoingMail(from: a.address,
                                to: MailAddress.parseInput(to),
                                cc: MailAddress.parseInput(cc),
                                bcc: MailAddress.parseInput(bcc),
                                subject: subject,
                                body: text,
                                html: html,
                                attachments: attachments,
                                inReplyTo: isReply ? o?.messageId : nil,
                                references: refs)
        mail.priority = priority
        mail.readReceipt = readReceipt
        return mail
    }

    private func send() {
        guard let a = account else {
            error = tr("请先添加邮箱账户。", "Add a mail account first.")
            return
        }
        let typed = [to, cc, bcc].joined(separator: ",").filter { $0 == "@" }.count
        let parsed = MailAddress.parseInput(to).count + MailAddress.parseInput(cc).count + MailAddress.parseInput(bcc).count
        guard parsed > 0 else {
            error = tr("请填写至少一个有效的收件人地址。", "Enter at least one valid recipient.")
            return
        }
        if typed > parsed {
            error = tr("有收件人地址无法识别，请检查格式，例如：张三 <zhang@example.com>", "A recipient address couldn't be read. Use a format like: Jane <jane@example.com>")
            return
        }
        let answered = (request.mode == .reply || request.mode == .replyAll) ? request.originalRef : nil
        let removeDraft = request.mode == .draft ? request.originalRef : nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            let html = await ed.html()
            let text = await ed.text()
            let mail = buildMail(a, html: html, text: text)
            // 马上关闭写信页，后台发送（可撤销；失败自动存草稿）
            MailCenter.shared.sendWithUndo(mail, account: a, answered: answered, removeDraft: removeDraft)
            dismiss()
        }
    }

    private func saveDraft(thenClose: Bool) {
        guard let a = account else {
            dismiss()
            return
        }
        let replacing = request.mode == .draft ? request.originalRef : nil
        busy = tr("正在保存草稿…", "Saving draft…")
        Task {
            let html = await ed.html()
            let text = await ed.text()
            let mail = buildMail(a, html: html, text: text)
            do {
                try await MailCenter.shared.saveDraft(mail, account: a, replacing: replacing)
                busy = nil
                if thenClose { dismiss() }
            } catch {
                busy = nil
                self.error = error.localizedDescription
            }
        }
    }
}
