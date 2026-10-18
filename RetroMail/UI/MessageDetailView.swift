import SwiftUI
import UIKit
import WebKit
import QuickLook

struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// 链接处理：外部链接用 Safari 打开，mailto 打开写信，其余导航一律拦截。
class LinkPolicyCoordinator: NSObject, WKNavigationDelegate {
    var onMailto: ((String) -> Void)?

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
            onMailto?(addr.removingPercentEncoding ?? addr)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}

/// 可滚动、可缩放的邮件正文（全屏阅读用）。
struct HTMLView: UIViewRepresentable {
    let html: String
    var onMailto: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.dataDetectorTypes = [.link, .phoneNumber]
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        context.coordinator.onMailto = onMailto
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            wv.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: LinkPolicyCoordinator {
        var lastHTML: String?
    }
}

/// 高度随内容自动撑开的正文（会话卡片里用），可选折叠引用的历史内容。
struct AutoHeightHTMLView: UIViewRepresentable {
    let html: String
    let hideQuotes: Bool
    @Binding var height: CGFloat
    /// 宽邮件被缩小时回报缩放比例（< 1 表示已缩小）
    var onScaled: ((Double) -> Void)?
    var onQuoteDetected: ((Bool) -> Void)?
    var onMailto: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.dataDetectorTypes = [.link, .phoneNumber]
        let ucc = cfg.userContentController
        ucc.addUserScript(WKUserScript(source: Self.script(hide: hideQuotes), injectionTime: .atDocumentEnd,
                                       forMainFrameOnly: true, in: .defaultClient))
        ucc.add(context.coordinator, contentWorld: .defaultClient, name: "retro")
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 1), configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        context.coordinator.observe(wv)
        context.coordinator.lastHTML = html
        wv.loadHTMLString(html, baseURL: nil)
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.onMailto = onMailto
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            wv.loadHTMLString(html, baseURL: nil)
        }
    }

    static func dismantleUIView(_ wv: WKWebView, coordinator: Coordinator) {
        coordinator.observation = nil
        wv.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    final class Coordinator: LinkPolicyCoordinator, WKScriptMessageHandler {
        var parent: AutoHeightHTMLView
        var lastHTML: String?
        var observation: NSKeyValueObservation?

        init(_ parent: AutoHeightHTMLView) {
            self.parent = parent
            super.init()
            onMailto = parent.onMailto
        }

        /// 卡片里不允许双指缩放（会和页面滚动冲突），需要缩放时用全屏查看。
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.pinchGestureRecognizer?.isEnabled = false
            webView.scrollView.minimumZoomScale = 1
            webView.scrollView.maximumZoomScale = 1
        }

        func observe(_ wv: WKWebView) {
            observation = wv.scrollView.observe(\.contentSize, options: [.new]) { [weak self] sv, _ in
                let h = ceil(sv.contentSize.height)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if h > 0, abs(self.parent.height - h) > 1 {
                        self.parent.height = h
                    }
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let z = (body["z"] as? NSNumber)?.doubleValue {
                DispatchQueue.main.async { [weak self] in self?.parent.onScaled?(z) }
                return
            }
            let found = (body["q"] as? Bool) ?? false
            DispatchQueue.main.async { [weak self] in
                self?.parent.onQuoteDetected?(found)
            }
        }
    }

    /// 在独立的脚本环境中运行（邮件自身的脚本已被禁用）。
    static func script(hide: Bool) -> String {
        """
        (function(){
          var HIDE = \(hide ? "true" : "false");
          function hideQuotes(){
            var target = document.querySelector('#divRplyFwdMsg, div[id^="divRplyFwdMsg"], div[name="divRplyFwdMsg"], .gmail_quote, .gmail_extra, blockquote[type="cite"], #original-content, .moz-cite-prefix, #appendonsend, .yahoo_quoted, #mail-editor-reference-message-container, #isForwardContent, #isReplyContent, .ne-quoted, .re-quote');
            if (!target) {
              var re = /^(-{2,}\\s*(original message|原始邮件|原始郵件|original|forwarded message|转发的邮件)|_{10,}$|在.{2,80}(写|寫)道[:：]|on .{4,160} wrote:)/i;
              var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
              while (w.nextNode()) {
                var t = (w.currentNode.nodeValue || '').replace(/\\u00a0/g, ' ').trim();
                if (!t) continue;
                if (re.test(t)) { target = w.currentNode.parentElement; break; }
                if (/^(发件人|寄件者|from)\\s*[:：]/i.test(t)) {
                  var p = w.currentNode.parentElement;
                  var blk = (p.closest && p.closest('div,p,td')) || p;
                  if (/(发送时间|日期|sent|date)\\s*[:：]/i.test(blk.innerText || '')) { target = blk; break; }
                }
              }
            }
            if (!target || target === document.body) return false;
            var before = document.createRange();
            before.setStart(document.body, 0);
            before.setEndBefore(target);
            if (before.toString().replace(/\\s/g, '').length === 0) return false;
            var n = target;
            while (n && n !== document.body) {
              var s = n.nextSibling;
              while (s) {
                var nx = s.nextSibling;
                if (s.nodeType === 1) { s.style.display = 'none'; }
                else if (s.nodeType === 3) { s.nodeValue = ''; }
                s = nx;
              }
              n = n.parentNode;
            }
            target.style.display = 'none';
            return true;
          }
          function fit(){
            try {
              document.body.style.zoom = 1;
              var w = document.documentElement.clientWidth;
              var sw = document.documentElement.scrollWidth;
              var z = 1;
              if (sw > w + 4) { z = w / sw; document.body.style.zoom = z.toFixed(3); }
              window.webkit.messageHandlers.retro.postMessage({ z: z });
            } catch (e) {}
          }
          var found = false;
          try { if (HIDE) { found = hideQuotes(); } } catch (e) {}
          fit();
          try { window.webkit.messageHandlers.retro.postMessage({ q: found }); } catch (e) {}
          window.addEventListener('load', fit);
          var imgs = document.images;
          for (var i = 0; i < imgs.length; i++) { imgs[i].addEventListener('load', fit); }
        })();
        """
    }
}

// MARK: - 全屏查看（可双指缩放）

@MainActor
final class ZoomController: ObservableObject {
    weak var webView: WKWebView?
    @Published var percent = 100
    private(set) var fitScale: CGFloat = 1

    func didLoad(_ wv: WKWebView) {
        // 等图片等资源排版完成后再计算“适合宽度”的比例
        Task { @MainActor [weak self, weak wv] in
            var first = true
            for ms in [150, 450, 900] {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                guard let self = self, let wv = wv else { return }
                self.computeFit(wv, apply: first || wv.scrollView.zoomScale <= self.fitScale + 0.01)
                first = false
            }
        }
    }

    private func computeFit(_ wv: WKWebView, apply: Bool) {
        let sv = wv.scrollView
        let contentWidth = sv.contentSize.width / max(sv.zoomScale, 0.01)
        let width = sv.bounds.width
        guard contentWidth > 0, width > 0 else { return }
        fitScale = min(1, width / contentWidth)
        sv.minimumZoomScale = min(fitScale, 1) * 0.5
        sv.maximumZoomScale = 8
        if apply { set(fitScale, animated: false) }
        update()
    }

    func set(_ scale: CGFloat, animated: Bool = true) {
        guard let sv = webView?.scrollView else { return }
        sv.setZoomScale(min(max(scale, sv.minimumZoomScale), sv.maximumZoomScale), animated: animated)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.update()
        }
    }

    func zoomIn() { set((webView?.scrollView.zoomScale ?? 1) * 1.3) }
    func zoomOut() { set((webView?.scrollView.zoomScale ?? 1) / 1.3) }
    func fit() { set(fitScale) }
    func actual() { set(1) }

    func update() {
        percent = Int(((webView?.scrollView.zoomScale ?? 1) * 100).rounded())
    }
}

/// 可滚动、可双指缩放的完整邮件页面。
struct ZoomableMailView: UIViewRepresentable {
    let html: String
    @ObservedObject var zoom: ZoomController
    var onMailto: ((String) -> Void)?

    /// 卡片用的页面禁止缩放；全屏时换成允许缩放的设置。
    static func zoomable(_ page: String) -> String {
        page.replacingOccurrences(of: ParsedMessage.cardViewport, with: "width=device-width, initial-scale=1, minimum-scale=0.1, maximum-scale=8, user-scalable=yes")
    }

    func makeCoordinator() -> Coordinator { Coordinator(zoom: zoom) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.dataDetectorTypes = [.link, .phoneNumber]
        cfg.ignoresViewportScaleLimits = true
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.bouncesZoom = true
        zoom.webView = wv
        context.coordinator.lastHTML = html
        wv.loadHTMLString(Self.zoomable(html), baseURL: nil)
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        context.coordinator.onMailto = onMailto
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            wv.loadHTMLString(Self.zoomable(html), baseURL: nil)
        }
    }

    final class Coordinator: LinkPolicyCoordinator {
        let zoom: ZoomController
        var lastHTML: String?

        init(zoom: ZoomController) {
            self.zoom = zoom
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 不能替换 scrollView 的 delegate（WebKit 靠它缩放），改为监听双指手势来更新百分比
            webView.scrollView.pinchGestureRecognizer?.removeTarget(self, action: #selector(pinched(_:)))
            webView.scrollView.pinchGestureRecognizer?.addTarget(self, action: #selector(pinched(_:)))
            let z = zoom
            Task { @MainActor in z.didLoad(webView) }
        }

        @objc func pinched(_ g: UIPinchGestureRecognizer) {
            guard g.state == .ended || g.state == .cancelled else { return }
            let z = zoom
            Task { @MainActor in z.update() }
        }
    }
}

/// 全屏邮件：iPhone OS 3 导航栏 + 可缩放正文 + 底部缩放工具栏。
struct FullMessageViewer: View {
    let title: String
    let page: String
    var onMailto: ((String) -> Void)?
    @StateObject private var zoom = ZoomController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            IOS3NavBar(title: title) {
                EmptyView()
            } trailing: {
                Button(tr("完成", "Done")) { dismiss() }
                    .buttonStyle(BarButtonStyle(kind: .done))
            }
            ZoomableMailView(html: page, zoom: zoom, onMailto: onMailto)
                .background(Color.white)
            IOS3Toolbar {
                ToolbarIcon(symbol: "minus.magnifyingglass", label: tr("缩小", "Zoom Out")) { zoom.zoomOut() }
                ToolbarIcon(symbol: "arrow.left.and.right", label: tr("适合宽度", "Fit Width")) { zoom.fit() }
                ToolbarStatus(text: "\(zoom.percent)%")
                    .onTapGesture { zoom.actual() }
                ToolbarIcon(symbol: "1.magnifyingglass", label: tr("实际大小", "Actual Size")) { zoom.actual() }
                ToolbarIcon(symbol: "plus.magnifyingglass", label: tr("放大", "Zoom In")) { zoom.zoomIn() }
            }
        }
        .background(IOS3.cell.ignoresSafeArea())
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

enum AttachmentFiles {
    static func write(_ att: MailAttachment) throws -> URL {
        let safe = att.filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(safe.isEmpty ? "attachment" : safe)
        try att.data.write(to: url)
        return url
    }

    static func icon(for mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.contains("zip") || mime.contains("compressed") || mime.contains("rar") { return "doc.zipper" }
        if mime.contains("sheet") || mime.contains("excel") { return "tablecells" }
        if mime.hasPrefix("text/") { return "doc.plaintext" }
        return "doc"
    }
}
