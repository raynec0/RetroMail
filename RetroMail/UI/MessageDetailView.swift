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
              if (sw > w + 4) { document.body.style.zoom = (w / sw).toFixed(3); }
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
