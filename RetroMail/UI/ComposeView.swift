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

    var originalRef: (folder: String, uid: Int)? {
        guard let f = originalFolder, let u = originalUID else { return nil }
        return (f, u)
    }
}

struct ComposeView: View {
    let request: ComposeRequest
    @ObservedObject private var store = AccountStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var accountId: UUID?
    @State private var to = ""
    @State private var cc = ""
    @State private var bcc = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var initialBody = ""
    @State private var showCc = false
    @State private var attachments: [OutgoingAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles = false
    @State private var busy: String?
    @State private var error: String?
    @State private var confirmClose = false
    @State private var prepared = false

    private var account: MailAccount? {
        store.accounts.first { $0.id == accountId } ?? store.accounts.first
    }

    private var windowTitle: String {
        switch request.mode {
        case .new: return "新邮件"
        case .reply, .replyAll: return "回复"
        case .forward: return "转发"
        case .draft: return "编辑草稿"
        }
    }

    private var isDirty: Bool {
        !to.isEmpty || !cc.isEmpty || !subject.isEmpty || bodyText != initialBody || !attachments.isEmpty
    }

    var body: some View {
        ZStack {
            DitherBackground()
            RetroWindow(title: windowTitle, onClose: { if isDirty { confirmClose = true } else { dismiss() } }) {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            fields
                            if !attachments.isEmpty { attachmentChips }
                            TextEditor(text: $bodyText)
                                .font(RT.font(14))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 300)
                                .padding(4)
                                .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                        }
                        .padding(10)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    RetroDivider()
                    bottomBar
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .foregroundColor(.black)
        .busyOverlay(busy != nil, busy ?? "")
        .retroAlert($error)
        .confirmationDialog("这封邮件还没有发送", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("存为草稿") { saveDraft(thenClose: true) }
            Button("放弃", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .onAppear(perform: prepare)
    }

    // MARK: 表单

    @ViewBuilder
    private var fields: some View {
        if store.accounts.count > 1 {
            HStack(spacing: 6) {
                Text("发件人").font(RT.font(13, .bold)).frame(width: 76, alignment: .trailing)
                Menu {
                    ForEach(store.accounts) { a in
                        Button(a.title) { accountId = a.id }
                    }
                } label: {
                    HStack {
                        Text(account?.title ?? "").font(RT.font(13)).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                }
            }
        }
        RetroField(label: "收件人", text: $to, placeholder: "多个地址用逗号分隔", keyboard: .emailAddress)
        if showCc {
            RetroField(label: "抄送", text: $cc, keyboard: .emailAddress)
            RetroField(label: "密送", text: $bcc, keyboard: .emailAddress)
        } else {
            HStack {
                Spacer().frame(width: 82)
                Button("＋ 抄送 / 密送") { showCc = true }
                    .font(RT.font(12))
                    .buttonStyle(.plain)
            }
        }
        RetroField(label: "主题", text: $subject)
    }

    private var attachmentChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(attachments) { a in
                HStack(spacing: 6) {
                    Image(systemName: "paperclip")
                    Text(a.filename).lineLimit(1)
                    Spacer()
                    Text(Fmt.size(a.data.count))
                    Button {
                        attachments.removeAll { $0.id == a.id }
                    } label: {
                        Image(systemName: "xmark.square")
                    }
                    .buttonStyle(.plain)
                }
                .font(RT.font(12))
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .overlay(Rectangle().stroke(Color.black, style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
            }
            Text("共 \(Fmt.size(attachments.reduce(0) { $0 + $1.data.count }))（多数服务器限制 20–50 MB）")
                .font(RT.font(10))
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 6) {
            PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos])) {
                Image(systemName: "photo")
            }
            .buttonStyle(RetroButtonStyle(compact: true))
            Button {
                showFiles = true
            } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(RetroButtonStyle(compact: true))
            Spacer(minLength: 0)
            Button("存草稿") { saveDraft(thenClose: true) }
                .buttonStyle(RetroButtonStyle(compact: true))
            Button("发送") { send() }
                .buttonStyle(RetroButtonStyle(isDefault: true, compact: true))
        }
        .padding(8)
    }

    // MARK: 预填

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        accountId = request.account?.id ?? store.accounts.first?.id
        to = request.to
        let sig = account.map { $0.signature.isEmpty ? "" : "\n\n-- \n" + $0.signature } ?? ""

        guard let o = request.original else {
            bodyText = sig
            initialBody = bodyText
            return
        }
        let me = account?.email ?? ""
        let fromLine = o.from.map(\.full).joined(separator: ", ")
        let when = o.date.map { Fmt.long($0) } ?? ""
        let original = o.plainText

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
            ccList = unique(ccList.filter { $0.email.caseInsensitiveCompare(me) != .orderedSame })
            to = toList.map(\.full).joined(separator: ", ")
            cc = ccList.map(\.full).joined(separator: ", ")
            showCc = !cc.isEmpty
            subject = prefixed("Re: ", o.subject)
            let quoted = original.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            bodyText = "\n" + sig + "\n\n在 \(when)，\(fromLine) 写道：\n" + quoted
        case .forward:
            subject = prefixed("Fwd: ", o.subject)
            var head = "\n" + sig + "\n\n---------- 转发的邮件 ----------\n"
            head += "发件人：\(fromLine)\n"
            head += "日期：\(when)\n"
            head += "主题：\(o.subject)\n"
            head += "收件人：\(o.to.map(\.full).joined(separator: ", "))\n"
            if !o.cc.isEmpty { head += "抄送：\(o.cc.map(\.full).joined(separator: ", "))\n" }
            bodyText = head + "\n" + original
            attachments = o.attachments.map {
                OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
            }
        case .draft:
            to = o.to.map(\.full).joined(separator: ", ")
            cc = o.cc.map(\.full).joined(separator: ", ")
            showCc = !cc.isEmpty
            subject = o.subject
            bodyText = original
            attachments = o.attachments.map {
                OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
            }
        case .new:
            bodyText = sig
        }
        initialBody = bodyText
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

    // MARK: 附件

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
                    self.error = "无法读取文件：\(error.localizedDescription)"
                }
            }
        case .failure(let e):
            error = e.localizedDescription
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
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
        photoItems = []
    }

    // MARK: 发送 / 草稿

    private func buildMail(_ a: MailAccount) -> OutgoingMail {
        let o = request.original
        var refs: String?
        if request.mode == .reply || request.mode == .replyAll || request.mode == .forward,
           let mid = o?.messageId {
            refs = [o?.references, mid].compactMap { $0 }.joined(separator: " ")
        }
        let isReply = request.mode == .reply || request.mode == .replyAll
        return OutgoingMail(from: a.address,
                            to: MailAddress.parseInput(to),
                            cc: MailAddress.parseInput(cc),
                            bcc: MailAddress.parseInput(bcc),
                            subject: subject,
                            body: bodyText,
                            attachments: attachments,
                            inReplyTo: isReply ? o?.messageId : nil,
                            references: refs)
    }

    private func send() {
        guard let a = account else {
            error = "请先添加邮箱账户。"
            return
        }
        let mail = buildMail(a)
        guard !mail.allRecipients.isEmpty else {
            error = "请填写至少一个有效的收件人地址。"
            return
        }
        let typed = [to, cc, bcc].joined(separator: ",").filter { $0 == "@" }.count
        if typed > mail.allRecipients.count {
            error = "有收件人地址无法识别，请检查格式，例如：张三 <zhang@example.com>"
            return
        }
        let answered = (request.mode == .reply || request.mode == .replyAll) ? request.originalRef : nil
        let removeDraft = request.mode == .draft ? request.originalRef : nil
        busy = "正在发送…"
        Task {
            do {
                try await MailCenter.shared.send(mail, account: a, answered: answered, removeDraft: removeDraft)
                busy = nil
                dismiss()
            } catch {
                busy = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func saveDraft(thenClose: Bool) {
        guard let a = account else { dismiss(); return }
        let mail = buildMail(a)
        let replacing = request.mode == .draft ? request.originalRef : nil
        busy = "正在保存草稿…"
        Task {
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
