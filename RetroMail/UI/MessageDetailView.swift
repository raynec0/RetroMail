import SwiftUI
import UIKit
import WebKit
import QuickLook

struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct MessageDetailView: View {
    @ObservedObject var list: MessageListModel
    let summary: MessageSummary

    @State private var parsed: ParsedMessage?
    @State private var loading = true
    @State private var error: String?
    @State private var loadRemote = false
    @State private var expandedHeader = false
    @State private var compose: ComposeRequest?
    @State private var preview: PreviewItem?
    @State private var showMove = false
    @Environment(\.dismiss) private var dismiss

    private var current: MessageSummary {
        list.visible.first { $0.uid == summary.uid } ?? summary
    }

    private var isDraft: Bool { list.folder.role == .drafts }

    var body: some View {
        RetroScreen(title: summary.subject.isEmpty ? "（无主题）" : summary.subject) {
            VStack(spacing: 0) {
                header
                RetroDivider()
                bodyArea
                RetroDivider()
                toolbar
            }
        }
        .retroAlert($error)
        .task { await load() }
        .fullScreenCover(item: $compose) { ComposeView(request: $0) }
        .sheet(item: $preview) { item in
            QuickLookView(url: item.url).ignoresSafeArea()
        }
        .sheet(isPresented: $showMove) {
            FolderPickerView(account: list.account, excluding: list.folder.path) { dest in
                let uid = summary.uid
                Task {
                    await list.move([uid], to: dest)
                    dismiss()
                }
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        let from = parsed?.from ?? (summary.from.map { [$0] } ?? [])
        let to = parsed?.to ?? summary.to
        let cc = parsed?.cc ?? summary.cc
        return VStack(alignment: .leading, spacing: 5) {
            Text(summary.subject.isEmpty ? "（无主题）" : summary.subject)
                .font(RT.font(16, .bold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            headerLine("发件人", from.map(\.full).joined(separator: ", "))
            headerLine("收件人", to.map { expandedHeader ? $0.full : $0.display }.joined(separator: ", "))
            if !cc.isEmpty {
                headerLine("抄　送", cc.map { expandedHeader ? $0.full : $0.display }.joined(separator: ", "))
            }
            headerLine("日　期", Fmt.long(parsed?.date ?? summary.date))
        }
        .foregroundColor(.black)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { expandedHeader.toggle() }
    }

    private func headerLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label + "：").font(RT.font(12, .bold))
            Text(value.isEmpty ? "—" : value)
                .font(RT.font(12))
                .lineLimit(expandedHeader ? nil : 2)
                .textSelection(.enabled)
        }
    }

    // MARK: 正文

    @ViewBuilder
    private var bodyArea: some View {
        if let p = parsed {
            VStack(spacing: 0) {
                if p.hasRemoteContent && !loadRemote {
                    HStack(spacing: 8) {
                        Image(systemName: "photo")
                        Text("已阻止远程图片").font(RT.font(12))
                        Spacer()
                        Button("显示") { loadRemote = true }
                            .buttonStyle(RetroButtonStyle(compact: true))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    RetroDivider(dotted: true)
                }
                HTMLView(html: p.renderHTML(allowRemote: loadRemote)) { mailto in
                    compose = ComposeRequest(account: list.account, to: mailto)
                }
                if !p.attachments.isEmpty {
                    attachmentList(p.attachments)
                }
            }
        } else if loading {
            VStack {
                Spacer()
                RetroBusy(text: "正在接收邮件…")
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 10) {
                Spacer()
                Text("无法载入这封邮件").font(RT.font(13))
                Button("重试") { Task { await load() } }
                    .buttonStyle(RetroButtonStyle(compact: true))
                Spacer()
            }
            .foregroundColor(.black)
            .frame(maxWidth: .infinity)
        }
    }

    private func attachmentList(_ items: [MailAttachment]) -> some View {
        VStack(spacing: 0) {
            RetroDivider()
            HStack {
                Text("附件 (\(items.count))").font(RT.font(11, .bold))
                Spacer()
            }
            .foregroundColor(.black)
            .padding(.horizontal, 10)
            .padding(.top, 5)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { att in
                        Button {
                            open(att)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: icon(for: att.mimeType))
                                    .frame(width: 18)
                                Text(att.filename).lineLimit(1)
                                Spacer()
                                Text(Fmt.size(att.data.count))
                            }
                            .font(RT.font(13))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(InvertOnPressStyle())
                    }
                }
            }
            .frame(maxHeight: min(CGFloat(items.count) * 36, 130))
        }
    }

    private func icon(for mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.contains("zip") || mime.contains("compressed") || mime.contains("rar") { return "doc.zipper" }
        if mime.hasPrefix("text/") { return "doc.plaintext" }
        return "doc"
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 0) {
            if isDraft {
                ToolIcon(symbol: "square.and.pencil", label: "编辑") { startCompose(.draft) }
            } else {
                ToolIcon(symbol: "arrowshape.turn.up.left", label: "回复") { startCompose(.reply) }
                ToolIcon(symbol: "arrowshape.turn.up.left.2", label: "全部") { startCompose(.replyAll) }
                ToolIcon(symbol: "arrowshape.turn.up.right", label: "转发") { startCompose(.forward) }
            }
            ToolIcon(symbol: current.seen ? "envelope.badge" : "envelope.open",
                     label: current.seen ? "未读" : "已读") {
                let target = !current.seen
                Task { await list.setSeen([summary.uid], target) }
            }
            ToolIcon(symbol: current.flagged ? "flag.slash" : "flag",
                     label: current.flagged ? "取消" : "旗标") {
                let target = !current.flagged
                Task { await list.setFlagged([summary.uid], target) }
            }
            ToolIcon(symbol: "folder", label: "移动") { showMove = true }
            ToolIcon(symbol: "trash", label: "删除") {
                let uid = summary.uid
                Task {
                    await list.delete([uid])
                    dismiss()
                }
            }
        }
        .foregroundColor(.black)
    }

    private func startCompose(_ mode: ComposeRequest.Mode) {
        guard let p = parsed else { return }
        compose = ComposeRequest(mode: mode, account: list.account, original: p,
                                 originalFolder: list.folder.path, originalUID: summary.uid)
    }

    // MARK: 载入

    private func load() async {
        loading = true
        defer { loading = false }
        let accountId = list.account.id
        let path = list.folder.path
        let uid = summary.uid
        do {
            let raw: Data
            if let cached = DiskCache.loadRaw(account: accountId, folder: path, uid: uid) {
                raw = cached
            } else {
                raw = try await list.client.perform { try await $0.fetchRaw(path, uid: uid) }
                DiskCache.saveRaw(raw, account: accountId, folder: path, uid: uid)
            }
            parsed = await Task.detached { ParsedMessage.parse(raw) }.value
            if !current.seen {
                await list.setSeen([uid], true)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func open(_ att: MailAttachment) {
        let safe = att.filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(safe.isEmpty ? "附件" : safe)
            try att.data.write(to: url)
            preview = PreviewItem(url: url)
        } catch {
            self.error = "无法打开附件：\(error.localizedDescription)"
        }
    }
}

// MARK: - 网页正文

struct HTMLView: UIViewRepresentable {
    let html: String
    var onMailto: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.dataDetectorTypes = [.link, .phoneNumber]
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .white
        wv.scrollView.backgroundColor = .white
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            wv.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLView
        var lastHTML: String?

        init(_ parent: HTMLView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "about" || scheme == "data" {
                decisionHandler(.allow)
                return
            }
            if scheme == "mailto" {
                var addr = String(url.absoluteString.dropFirst("mailto:".count))
                if let q = addr.firstIndex(of: "?") { addr = String(addr[..<q]) }
                parent.onMailto?(addr.removingPercentEncoding ?? addr)
                decisionHandler(.cancel)
                return
            }
            if navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}

// MARK: - 附件预览

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        return UINavigationController(rootViewController: ql)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
