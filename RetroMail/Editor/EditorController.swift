import SwiftUI
import UIKit
import WebKit

/// 光标处的格式状态（用于点亮工具栏按钮）。
struct EditorState: Equatable {
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var sup = false
    var sub = false
    var ul = false
    var ol = false
    var align = "left"
    var block = ""
    var font = ""
    var size = ""
    var color = ""
    var inTable = false
    var inList = false
    var link = ""
    var painter = false

    init() {}

    init(_ d: [String: Any]) {
        func b(_ k: String) -> Bool {
            if let v = d[k] as? Bool { return v }
            if let v = d[k] as? NSNumber { return v.boolValue }
            return false
        }
        func s(_ k: String) -> String { (d[k] as? String) ?? "" }
        bold = b("bold")
        italic = b("italic")
        underline = b("underline")
        strike = b("strikeThrough")
        sup = b("superscript")
        sub = b("subscript")
        ul = b("insertUnorderedList")
        ol = b("insertOrderedList")
        if b("justifyCenter") {
            align = "center"
        } else if b("justifyRight") {
            align = "right"
        } else if b("justifyFull") {
            align = "justify"
        } else {
            align = "left"
        }
        block = s("block")
        font = s("font")
        size = s("size")
        color = s("color")
        inTable = b("inTable")
        inList = b("inList")
        link = s("link")
        painter = b("painter")
    }

    /// 当前字号（磅）。
    var sizePt: String {
        guard let px = Double(size.replacingOccurrences(of: "px", with: "")) else { return "" }
        let pt = (px * 0.75 * 2).rounded() / 2
        return pt == pt.rounded() ? String(Int(pt)) : String(pt)
    }

    /// 当前字体的第一个名字。
    var fontName: String {
        let first = font.split(separator: ",").first.map(String.init) ?? ""
        return first.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
    }
}

@MainActor
final class EditorController: NSObject, ObservableObject, WKScriptMessageHandler {
    @Published var state = EditorState()
    @Published var focused = false
    @Published var dirty = false

    weak var webView: WKWebView?
    private var ready = false
    private var pendingHTML: String?

    func attach(_ wv: WKWebView) {
        webView = wv
    }

    func setInitialHTML(_ html: String) {
        if ready {
            call("setHTML", html)
            dirty = false
        } else {
            pendingHTML = html
        }
    }

    func run(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func call(_ fn: String, _ args: Any?...) {
        run("RE.\(fn)(\(args.map(Self.js).joined(separator: ",")))")
    }

    func eval(_ js: String) async -> Any? {
        guard let wv = webView else { return nil }
        return await withCheckedContinuation { (c: CheckedContinuation<Any?, Never>) in
            wv.evaluateJavaScript(js) { result, _ in
                c.resume(returning: result)
            }
        }
    }

    func callResult(_ fn: String, _ args: Any?...) async -> Any? {
        await eval("RE.\(fn)(\(args.map(Self.js).joined(separator: ",")))")
    }

    /// iOS 18.2+：打开 Apple“写作工具”（作用于当前选中的文字）。
    var canShowWritingTools: Bool {
        guard let wv = webView else { return false }
        return wv.responds(to: NSSelectorFromString("showWritingTools:"))
    }

    func showWritingTools() {
        guard let wv = webView else { return }
        let sel = NSSelectorFromString("showWritingTools:")
        if wv.responds(to: sel) {
            wv.becomeFirstResponder()
            wv.perform(sel, with: nil)
        }
    }

    func html() async -> String { (await eval("RE.html()") as? String) ?? "" }
    func text() async -> String { (await eval("RE.text()") as? String) ?? "" }
    func bodyText() async -> String { (await eval("RE.bodyText()") as? String) ?? "" }
    func selectedText() async -> String { (await eval("RE.selectedText()") as? String) ?? "" }

    static func js(_ v: Any?) -> String {
        switch v {
        case nil:
            return "null"
        case let b as Bool:
            return b ? "true" : "false"
        case let i as Int:
            return String(i)
        case let d as Double:
            return String(d)
        case let s as String:
            if let data = try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "\"\""
        default:
            return "null"
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "state":
            if let d = message.body as? [String: Any] {
                let s = EditorState(d)
                if s != state { state = s }
            }
        case "ready":
            ready = true
            if let p = pendingHTML {
                pendingHTML = nil
                call("setHTML", p)
                dirty = false
            }
        case "focus":
            focused = (message.body as? Bool) ?? ((message.body as? NSNumber)?.boolValue ?? false)
        case "changed":
            if !dirty { dirty = true }
        default:
            break
        }
    }
}

/// 防止 WKUserContentController 强引用控制器造成循环引用。
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

struct RichEditorView: UIViewRepresentable {
    let controller: EditorController
    var placeholder: String

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let ucc = cfg.userContentController
        let handler = WeakScriptHandler(controller)
        for name in ["state", "ready", "focus", "changed"] {
            ucc.add(handler, name: name)
        }
        #if compiler(>=6.0)
        if #available(iOS 18.0, *) {
            // 选中文字后可以用 Apple 的“写作工具”（含已登录的 ChatGPT）
            cfg.writingToolsBehavior = .complete
        }
        #endif
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.overrideUserInterfaceStyle = .light
        wv.isOpaque = true
        wv.backgroundColor = .white
        wv.scrollView.backgroundColor = .white
        wv.scrollView.keyboardDismissMode = .interactive
        controller.attach(wv)
        wv.loadHTMLString(EditorHTML.page(placeholder: placeholder), baseURL: nil)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        uiView.configuration.userContentController.removeAllScriptMessageHandlers()
    }
}

// MARK: - 颜色工具

enum HexColor {
    static func hex(_ c: Color) -> String {
        let ui = UIColor(c)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }

    static func color(_ hex: String) -> Color {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt32(s, radix: 16) ?? 0
        return Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    /// 在 base 与白色/黑色之间混合：amount > 0 变浅，< 0 变深。
    static func mix(_ hex: String, _ amount: Double) -> String {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt32(s, radix: 16) ?? 0
        let comps = [Double((v >> 16) & 0xff), Double((v >> 8) & 0xff), Double(v & 0xff)]
        let out = comps.map { c -> Int in
            let t = amount >= 0 ? c + (255 - c) * amount : c * (1 + amount)
            return Int(max(0, min(255, round(t))))
        }
        return String(format: "#%02X%02X%02X", out[0], out[1], out[2])
    }
}
