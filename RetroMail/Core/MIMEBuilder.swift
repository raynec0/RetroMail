import Foundation
import UniformTypeIdentifiers

struct OutgoingAttachment: Identifiable {
    let id = UUID()
    var filename: String
    var mimeType: String
    var data: Data

    static func mimeType(forFilename name: String) -> String {
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}

enum MailPriority: Int, CaseIterable, Identifiable {
    case high = 1, normal = 3, low = 5
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .high: return tr("重要性：高", "High importance")
        case .normal: return tr("重要性：普通", "Normal importance")
        case .low: return tr("重要性：低", "Low importance")
        }
    }
}

struct OutgoingMail {
    var from: MailAddress
    var to: [MailAddress]
    var cc: [MailAddress]
    var bcc: [MailAddress]
    var subject: String
    /// 纯文本版本（总是发送，作为 HTML 的备选）
    var body: String
    /// 富文本正文（编辑器的 innerHTML）；nil 表示只发纯文本
    var html: String?
    var attachments: [OutgoingAttachment]
    var inReplyTo: String?
    var references: String?
    var priority: MailPriority = .normal
    var readReceipt = false

    var allRecipients: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for a in to + cc + bcc where !seen.contains(a.email.lowercased()) {
            seen.insert(a.email.lowercased())
            out.append(a.email)
        }
        return out
    }
}

enum MIMEBuilder {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    private static let b64Options: Data.Base64EncodingOptions = [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]

    /// 发出邮件 HTML 的默认字体（与编辑器一致，接近 Outlook 默认）。
    static let defaultBodyStyle = "font-family: Calibri, 'Microsoft YaHei', 'PingFang SC', Arial, sans-serif; font-size: 11pt; line-height: 1.4; color: #000000;"

    private indirect enum Node {
        case leaf(headers: [(String, String)], data: Data)
        case multi(subtype: String, parts: [Node])
    }

    static func build(_ mail: OutgoingMail, includeBcc: Bool) -> Data {
        let domain = mail.from.email.split(separator: "@").last.map(String.init) ?? "retromail.local"
        var h = ""
        func add(_ k: String, _ v: String) { h += "\(k): \(v)\r\n" }

        add("Date", dateFormatter.string(from: Date()))
        add("From", mail.from.mimeString)
        if !mail.to.isEmpty { add("To", mail.to.map(\.mimeString).joined(separator: ",\r\n ")) }
        if !mail.cc.isEmpty { add("Cc", mail.cc.map(\.mimeString).joined(separator: ",\r\n ")) }
        if includeBcc && !mail.bcc.isEmpty { add("Bcc", mail.bcc.map(\.mimeString).joined(separator: ",\r\n ")) }
        add("Subject", HeaderCoding.encode(mail.subject))
        add("Message-ID", "<\(UUID().uuidString)@\(domain)>")
        if let r = mail.inReplyTo, !r.isEmpty { add("In-Reply-To", r) }
        if let r = mail.references, !r.isEmpty { add("References", r) }
        switch mail.priority {
        case .high:
            add("X-Priority", "1 (Highest)")
            add("Importance", "High")
        case .low:
            add("X-Priority", "5 (Lowest)")
            add("Importance", "Low")
        case .normal:
            break
        }
        if mail.readReceipt {
            add("Disposition-Notification-To", mail.from.mimeString)
            add("Return-Receipt-To", mail.from.mimeString)
        }
        add("MIME-Version", "1.0")
        add("X-Mailer", "RetroMail 2.0 (iOS)")

        let text = mail.body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let textNode = Node.leaf(headers: [("Content-Type", "text/plain; charset=UTF-8")], data: Data(text.utf8))

        var bodyNode = textNode
        if let html = mail.html {
            let (rewritten, images) = extractInlineImages(html, domain: domain)
            let full = wrapHTML(rewritten)
            let htmlNode = Node.leaf(headers: [("Content-Type", "text/html; charset=UTF-8")], data: Data(full.utf8))
            let rich: Node
            if images.isEmpty {
                rich = htmlNode
            } else {
                rich = .multi(subtype: "related", parts: [htmlNode] + images.map { img in
                    Node.leaf(headers: [("Content-Type", "\(img.mime); name=\"\(img.name)\""),
                                        ("Content-ID", "<\(img.cid)>"),
                                        ("Content-Disposition", "inline; filename=\"\(img.name)\"")],
                              data: img.data)
                })
            }
            bodyNode = .multi(subtype: "alternative", parts: [textNode, rich])
        }

        var root = bodyNode
        if !mail.attachments.isEmpty {
            root = .multi(subtype: "mixed", parts: [bodyNode] + mail.attachments.map { a in
                let n = HeaderCoding.encode(a.filename.replacingOccurrences(of: "\"", with: "'"), fold: false)
                return Node.leaf(headers: [("Content-Type", "\(a.mimeType); name=\"\(n)\""),
                                           ("Content-Disposition", "attachment; filename=\"\(n)\"")],
                                 data: a.data)
            })
        }

        let (rootHeaders, rootBody) = render(root)
        for (k, v) in rootHeaders { add(k, v) }
        var out = Data(h.utf8)
        out.append(Data("\r\n".utf8))
        out.append(rootBody)
        return out
    }

    private static func render(_ node: Node) -> ([(String, String)], Data) {
        switch node {
        case .leaf(let headers, let data):
            var hs = headers
            hs.append(("Content-Transfer-Encoding", "base64"))
            var body = Data(data.base64EncodedString(options: b64Options).utf8)
            body.append(Data("\r\n".utf8))
            return (hs, body)
        case .multi(let subtype, let parts):
            let boundary = "----=_RetroMail_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            var body = Data()
            if subtype == "mixed" {
                body.append(Data("This is a multi-part message in MIME format.\r\n".utf8))
            }
            for p in parts {
                let (ph, pb) = render(p)
                var head = "--\(boundary)\r\n"
                for (k, v) in ph { head += "\(k): \(v)\r\n" }
                head += "\r\n"
                body.append(Data(head.utf8))
                body.append(pb)
            }
            body.append(Data("--\(boundary)--\r\n".utf8))
            return ([("Content-Type", "multipart/\(subtype); boundary=\"\(boundary)\"")], body)
        }
    }

    static func wrapHTML(_ inner: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1"></head>
        <body><div style="\(defaultBodyStyle)">\(inner)</div></body></html>
        """
    }

    struct InlineImage {
        var cid: String
        var mime: String
        var name: String
        var data: Data
    }

    private static let dataURIRegex = try! NSRegularExpression(
        pattern: "src\\s*=\\s*([\"'])data:([a-zA-Z0-9.+/-]+);base64,([A-Za-z0-9+/=\\s]+)\\1",
        options: [.caseInsensitive])

    /// 把 <img src="data:..."> 换成 cid 引用，图片作为 multipart/related 的内嵌部分发送。
    static func extractInlineImages(_ html: String, domain: String) -> (String, [InlineImage]) {
        let ns = html as NSString
        let matches = dataURIRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (html, []) }
        var images: [InlineImage] = []
        var out = html
        for (i, m) in matches.enumerated().reversed() {
            let mime = ns.substring(with: m.range(at: 2)).lowercased()
            let b64 = ns.substring(with: m.range(at: 3))
            let data = TransferDecoding.base64(Data(b64.utf8))
            let ext = mime.split(separator: "/").last.map(String.init) ?? "png"
            let cid = "image\(i + 1).\(UUID().uuidString.prefix(8))@\(domain)"
            images.insert(InlineImage(cid: cid, mime: mime, name: "image\(i + 1).\(ext == "jpeg" ? "jpg" : ext)", data: data), at: 0)
            if let r = Range(m.range, in: out) {
                out.replaceSubrange(r, with: "src=\"cid:\(cid)\"")
            }
        }
        return (out, images)
    }
}
