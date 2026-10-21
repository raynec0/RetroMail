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

    // MARK: 操作反馈

    struct Toast: Equatable {
        let id = UUID()
        let text: String
        let ok: Bool
    }

    @Published var toast: Toast?

    /// 工具栏按钮用：执行命令，并根据结果给出震动和一句提示（生效了 / 为什么没生效）。
    func act(_ fn: String, _ args: Any?...) {
        let argList = args.map(Self.js).joined(separator: ",")
        let first = args.first.flatMap { $0 }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard let wv = webView, ready else {
            show(tr("编辑器还在加载，请稍等一下再点。", "The editor is still loading. Try again in a moment."), ok: false)
            return
        }
        wv.evaluateJavaScript("RE.run(\(Self.js(fn)), [\(argList)])") { [weak self] result, error in
            Task { @MainActor in
                self?.report(fn, first, result as? [String: Any], error)
            }
        }
    }

    private func report(_ fn: String, _ arg: Any?, _ r: [String: Any]?, _ error: Error?) {
        let label = Self.label(fn, arg as? String)
        guard let r = r, (r["ok"] as? Bool) ?? ((r["ok"] as? NSNumber)?.boolValue ?? false) else {
            let why = (r?["error"] as? String) ?? error?.localizedDescription ?? ""
            show(tr("\(label)没有完成", "\(label) didn't work") + (why.isEmpty ? "" : "：" + why), ok: false)
            return
        }
        func b(_ k: String) -> Bool { (r[k] as? Bool) ?? ((r[k] as? NSNumber)?.boolValue ?? false) }
        let changed = b("changed"), fmt = b("formatChanged"), hadSel = b("hadSel"), hadFocus = b("hadFocus")
        let ret = r["ret"] as? String
        switch ret {
        case "notable"?:
            show(tr("请先把光标放在表格里，再点“\(label)”。", "Put the cursor in a table first, then tap \(label)."), ok: false); return
        case "nonext"?:
            show(tr("右边没有可以合并的单元格。", "There's no cell to the right to merge."), ok: false); return
        case "nosel"?:
            show(tr("请先选中要修改的文字。", "Select some text first."), ok: false); return
        case "nopainter"?:
            show(tr("请先点“格式刷”复制格式。", "Tap Format Painter first to copy a format."), ok: false); return
        default:
            break
        }
        if fn == "copyFormat" {
            show(tr("已复制格式：选中目标文字后点“应用格式”。", "Format copied: select text, then tap Apply."), ok: true); return
        }
        if fn == "cancelPainter" { return }
        if fn == "cmd", let a = arg as? String, a == "undo" || a == "redo", !changed {
            show(a == "undo" ? tr("没有可以撤销的操作。", "Nothing to undo.") : tr("没有可以重做的操作。", "Nothing to redo."), ok: false); return
        }
        if fn == "unlink", !changed {
            show(tr("光标不在链接上。", "The cursor isn't on a link."), ok: false); return
        }
        if changed {
            show("✓ " + label, ok: true)
        } else if fmt {
            show("✓ " + label + tr("（接下来输入的文字会使用这个格式）", " (applies to what you type next)"), ok: true)
        } else if !hadFocus {
            show(tr("请先点一下正文，把光标放到要修改的位置。", "Tap in the message first to place the cursor."), ok: false)
        } else if !hadSel {
            show(tr("“\(label)”没有变化：请先选中要修改的文字。", "\(label) changed nothing — select some text first."), ok: false)
        } else {
            show(tr("“\(label)”已经是这个效果了。", "\(label) is already applied."), ok: true)
        }
    }

    func show(_ text: String, ok: Bool) {
        if !ok { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        let t = Toast(text: text, ok: ok)
        toast = t
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: ok ? 1_400_000_000 : 2_600_000_000)
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }

    private static func label(_ fn: String, _ arg: String?) -> String {
        let cmds: [String: (String, String)] = [
            "undo": ("撤销", "Undo"), "redo": ("重做", "Redo"), "bold": ("加粗", "Bold"), "italic": ("倾斜", "Italic"),
            "underline": ("下划线", "Underline"), "strikeThrough": ("删除线", "Strikethrough"),
            "superscript": ("上标", "Superscript"), "subscript": ("下标", "Subscript"),
            "insertUnorderedList": ("项目符号", "Bullets"), "insertOrderedList": ("编号", "Numbering"),
            "outdent": ("减少缩进", "Outdent"), "indent": ("增加缩进", "Indent"),
            "justifyLeft": ("左对齐", "Align Left"), "justifyCenter": ("居中", "Center"),
            "justifyRight": ("右对齐", "Align Right"), "justifyFull": ("两端对齐", "Justify"),
            "insertHorizontalRule": ("分隔线", "Line"), "insertText": ("插入文字", "Insert Text"),
            "foreColor": ("字体颜色", "Font Color"), "hiliteColor": ("突出显示", "Highlight"),
            "fontName": ("字体", "Font"), "insertHTML": ("插入", "Insert"), "formatBlock": ("样式", "Style"),
        ]
        let fns: [String: (String, String)] = [
            "fontSize": ("字号", "Font Size"), "growFont": ("字号", "Font Size"), "color": ("字体颜色", "Font Color"),
            "highlight": ("突出显示", "Highlight"), "clear": ("清除格式", "Clear Formatting"), "block": ("样式", "Style"),
            "bullet": ("项目符号", "Bullets"), "number": ("编号", "Numbering"), "lineHeight": ("行距", "Line Spacing"),
            "spaceAfter": ("段后间距", "Spacing After"), "link": ("链接", "Link"), "unlink": ("取消链接", "Unlink"),
            "image": ("插入图片", "Insert Picture"), "table": ("插入表格", "Insert Table"),
            "addRow": ("插入行", "Insert Row"), "addCol": ("插入列", "Insert Column"), "delRow": ("删除行", "Delete Row"),
            "delCol": ("删除列", "Delete Column"), "delTable": ("删除表格", "Delete Table"), "merge": ("合并单元格", "Merge Cells"),
            "cellFill": ("单元格底纹", "Cell Shading"), "border": ("表格边框", "Table Border"), "tableWidth": ("表格宽度", "Table Width"),
            "changeCase": ("更改大小写", "Change Case"), "pasteFormat": ("应用格式", "Apply Format"), "copyFormat": ("格式刷", "Format Painter"),
            "replaceSelection": ("替换选中文字", "Replace Selection"), "replaceBody": ("替换正文", "Replace Body"),
            "insertHTML": ("插入", "Insert"),
        ]
        if fn == "cmd", let a = arg, let l = cmds[a] { return tr(l.0, l.1) }
        if let l = fns[fn] { return tr(l.0, l.1) }
        return tr("操作", "Action")
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
        cfg.processPool = WebWarmup.pool
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
