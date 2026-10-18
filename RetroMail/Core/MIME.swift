import Foundation

// MARK: - 字符集

enum Charset {
    static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    static func encoding(_ name: String?) -> String.Encoding? {
        guard var cs = name?.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")).lowercased(), !cs.isEmpty else {
            return nil
        }
        if let star = cs.firstIndex(of: "*") { cs = String(cs[..<star]) }
        switch cs {
        case "utf-8", "utf8", "us-ascii", "ascii", "unicode-1-1-utf-8":
            return .utf8
        case "gb2312", "gbk", "gb_2312-80", "x-gbk", "euc-cn", "cp936", "gb18030", "x-euc-cn", "chinese", "csgb2312":
            return gb18030
        case "iso-8859-1", "latin1", "l1":
            return .isoLatin1
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
            if cf == kCFStringEncodingInvalidId { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }

    static func decode(_ data: Data, charset: String?) -> String {
        if let enc = encoding(charset), let s = String(data: data, encoding: enc) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: gb18030) { return s }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - 传输编码

enum TransferDecoding {
    static func base64(_ data: Data) -> Data {
        var cleaned = Data()
        cleaned.reserveCapacity(data.count)
        for b in data where (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 43 || b == 47 {
            cleaned.append(b)
        }
        let rem = cleaned.count % 4
        if rem == 1 {
            cleaned.removeLast()
        } else if rem > 0 {
            cleaned.append(contentsOf: [UInt8](repeating: 61, count: 4 - rem))
        }
        return Data(base64Encoded: cleaned) ?? Data()
    }

    static func quotedPrintable(_ data: Data, header: Bool = false) -> Data {
        let bytes = [UInt8](data)
        var out = Data()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 61 { // "="
                if i + 1 < bytes.count && bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < bytes.count && bytes[i + 1] == 13 && bytes[i + 2] == 10 { i += 3; continue }
                if i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                    out.append(h << 4 | l)
                    i += 3
                    continue
                }
                out.append(b)
                i += 1
            } else if header && b == 95 { // "_"
                out.append(32)
                i += 1
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    static func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }

    static func percentDecode(_ s: String) -> Data {
        let b = Array(s.utf8)
        var out = Data()
        var i = 0
        while i < b.count {
            if b[i] == 37, i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) {
                out.append(h << 4 | l)
                i += 3
            } else {
                out.append(b[i])
                i += 1
            }
        }
        return out
    }
}

// MARK: - RFC 2047 头部编码

enum HeaderCoding {
    private static let regex = try! NSRegularExpression(pattern: "=\\?([^?\\s]+)\\?([BbQq])\\?([^?\\s]*)\\?=")

    static func decode(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return s }
        var result = ""
        var last = 0
        var pendingBytes = Data()
        var pendingCharset: String?

        func flush() {
            if let cs = pendingCharset {
                result += Charset.decode(pendingBytes, charset: cs)
            }
            pendingBytes = Data()
            pendingCharset = nil
        }

        for (idx, m) in matches.enumerated() {
            let between = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let onlySpace = between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let charset = ns.substring(with: m.range(at: 1))
            let enc = ns.substring(with: m.range(at: 2)).uppercased()
            let raw = Data(ns.substring(with: m.range(at: 3)).utf8)
            let bytes = enc == "B" ? TransferDecoding.base64(raw) : TransferDecoding.quotedPrintable(raw, header: true)

            if idx > 0 && onlySpace && pendingCharset?.lowercased() == charset.lowercased() {
                pendingBytes.append(bytes)
            } else {
                flush()
                if !(idx > 0 && onlySpace) { result += between }
                pendingBytes = bytes
                pendingCharset = charset
            }
            last = m.range.location + m.range.length
        }
        flush()
        result += ns.substring(from: last)
        return result
    }

    static func needsEncoding(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value > 126 || ($0.value < 32 && $0 != "\t") }
    }

    static func encode(_ s: String, fold: Bool = true) -> String {
        guard needsEncoding(s) else { return s }
        var words: [String] = []
        var chunk = ""
        for ch in s {
            if (chunk + String(ch)).utf8.count > 45, !chunk.isEmpty {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(ch)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words
            .map { "=?UTF-8?B?" + Data($0.utf8).base64EncodedString() + "?=" }
            .joined(separator: fold ? "\r\n " : " ")
    }
}

// MARK: - 头部

struct MIMEHeaders {
    var fields: [(name: String, value: String)]

    subscript(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func decodeRaw(_ d: Data) -> String {
        String(data: d, encoding: .utf8) ?? String(data: d, encoding: Charset.gb18030) ?? String(decoding: d, as: UTF8.self)
    }

    static func parse(_ data: Data) -> MIMEHeaders {
        let text = decodeRaw(data).replacingOccurrences(of: "\r\n", with: "\n")
        var fields: [(name: String, value: String)] = []
        var current: (name: String, value: String)?
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty {
                if current != nil || !fields.isEmpty { break }
                continue
            }
            if let f = line.first, f == " " || f == "\t" {
                if current != nil {
                    current!.value += " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if let c = current { fields.append(c) }
            if let colon = line.firstIndex(of: ":") {
                current = (String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                           String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            } else {
                current = nil
            }
        }
        if let c = current { fields.append(c) }
        return MIMEHeaders(fields: fields)
    }
}

/// 形如 `text/plain; charset="utf-8"` 的头部值，支持 RFC 2231 参数。
struct HeaderValue {
    var value: String
    var params: [String: String]

    static func parse(_ rawValue: String?) -> HeaderValue {
        guard let raw = rawValue, !raw.isEmpty else { return HeaderValue(value: "", params: [:]) }
        var segments: [String] = []
        var cur = ""
        var inQuote = false
        for ch in raw {
            if ch == "\"" { inQuote.toggle() }
            if ch == ";" && !inQuote {
                segments.append(cur)
                cur = ""
                continue
            }
            cur.append(ch)
        }
        segments.append(cur)

        let main = (segments.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        var rawParams: [(String, String)] = []
        for seg in segments.dropFirst() {
            guard let eq = seg.firstIndex(of: "=") else { continue }
            let k = seg[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var v = seg[seg.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2 && v.hasPrefix("\"") && v.hasSuffix("\"") {
                v = String(v.dropFirst().dropLast())
            }
            rawParams.append((k, v))
        }

        var params: [String: String] = [:]
        var continuations: [String: [(Int, String, Bool)]] = [:]
        var extendedSingles: [String: String] = [:]
        for (k, v) in rawParams {
            if let star = k.firstIndex(of: "*") {
                let base = String(k[..<star])
                let rest = String(k[k.index(after: star)...])
                if rest.isEmpty {
                    extendedSingles[base] = v
                } else {
                    let encoded = rest.hasSuffix("*")
                    let idx = Int(rest.replacingOccurrences(of: "*", with: "")) ?? 0
                    continuations[base, default: []].append((idx, v, encoded))
                }
            } else if params[k] == nil {
                params[k] = v
            }
        }
        for (base, v) in extendedSingles {
            continuations[base, default: []].append((0, v, true))
        }
        for (base, segs) in continuations {
            var bytes = Data()
            var charset: String?
            for (n, seg) in segs.sorted(by: { $0.0 < $1.0 }).enumerated() {
                var val = seg.1
                if seg.2 {
                    if n == 0 {
                        let pieces = val.components(separatedBy: "'")
                        if pieces.count >= 3 {
                            charset = pieces[0]
                            val = pieces[2...].joined(separator: "'")
                        }
                    }
                    bytes.append(TransferDecoding.percentDecode(val))
                } else {
                    bytes.append(Data(val.utf8))
                }
            }
            params[base] = Charset.decode(bytes, charset: charset)
        }
        return HeaderValue(value: main, params: params)
    }
}

// MARK: - MIME 结构

struct MIMEPart {
    var headers: MIMEHeaders
    var body: Data
    var contentType: HeaderValue
    var disposition: HeaderValue
    var children: [MIMEPart] = []

    static func parse(_ data: Data, depth: Int = 0) -> MIMEPart {
        let (h, b) = splitHeaderBody(data)
        let headers = MIMEHeaders.parse(h)
        var ct = HeaderValue.parse(headers["Content-Type"])
        if ct.value.isEmpty || !ct.value.contains("/") { ct.value = "text/plain" }
        var part = MIMEPart(headers: headers, body: b, contentType: ct,
                            disposition: HeaderValue.parse(headers["Content-Disposition"]))
        if ct.value.hasPrefix("multipart/"), let boundary = ct.params["boundary"], !boundary.isEmpty, depth < 20 {
            part.children = splitMultipart(b, boundary: boundary).map { parse($0, depth: depth + 1) }
        }
        return part
    }

    static func splitHeaderBody(_ d: Data) -> (Data, Data) {
        if d.starts(with: [13, 10]) { return (Data(), d.subdata(in: 2..<d.count)) }
        if d.starts(with: [10]) { return (Data(), d.subdata(in: 1..<d.count)) }
        let r1 = d.range(of: Data([13, 10, 13, 10]))
        let r2 = d.range(of: Data([10, 10]))
        var best = r1
        if let r2 = r2 {
            if r1 == nil || r2.lowerBound < r1!.lowerBound { best = r2 }
        }
        guard let r = best else { return (d, Data()) }
        return (d.subdata(in: 0..<r.lowerBound), d.subdata(in: r.upperBound..<d.count))
    }

    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let delim = Data(("--" + boundary).utf8)
        var parts: [Data] = []
        var searchStart = 0
        var currentStart: Int?
        while searchStart < body.count, let r = body.range(of: delim, in: searchStart..<body.count) {
            let atLineStart = r.lowerBound == 0 || body[r.lowerBound - 1] == 10
            if !atLineStart {
                searchStart = r.upperBound
                continue
            }
            if let cs = currentStart {
                var end = r.lowerBound
                if end > cs, body[end - 1] == 10 { end -= 1 }
                if end > cs, body[end - 1] == 13 { end -= 1 }
                parts.append(body.subdata(in: cs..<max(cs, end)))
            }
            var after = r.upperBound
            if after + 1 < body.count, body[after] == 45, body[after + 1] == 45 {
                return parts
            }
            while after < body.count, body[after] != 10 { after += 1 }
            if after < body.count { after += 1 }
            currentStart = after
            searchStart = after
        }
        if let cs = currentStart, cs < body.count {
            parts.append(body.subdata(in: cs..<body.count))
        }
        return parts
    }

    var decodedData: Data {
        let cte = (headers["Content-Transfer-Encoding"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        switch cte {
        case "base64": return TransferDecoding.base64(body)
        case "quoted-printable": return TransferDecoding.quotedPrintable(body)
        default: return body
        }
    }

    var text: String {
        Charset.decode(decodedData, charset: contentType.params["charset"])
    }

    var filename: String? {
        guard let n = disposition.params["filename"] ?? contentType.params["name"], !n.isEmpty else { return nil }
        return HeaderCoding.decode(n)
    }

    var contentId: String? {
        headers["Content-ID"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
    }
}

// MARK: - 解析后的完整邮件

struct MailAttachment: Identifiable {
    let id = UUID()
    var filename: String
    var mimeType: String
    var data: Data
    var contentId: String?
}

struct ParsedMessage {
    var subject: String = ""
    var from: [MailAddress] = []
    var to: [MailAddress] = []
    var cc: [MailAddress] = []
    var replyTo: [MailAddress] = []
    var date: Date?
    var messageId: String?
    var references: String?
    var text: String?
    var html: String?
    var attachments: [MailAttachment] = []

    static func parse(_ raw: Data) -> ParsedMessage {
        let root = MIMEPart.parse(raw)
        let h = root.headers
        var m = ParsedMessage()
        m.subject = HeaderCoding.decode(h["Subject"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        m.from = MailAddress.parseList(h["From"])
        m.to = MailAddress.parseList(h["To"])
        m.cc = MailAddress.parseList(h["Cc"])
        m.replyTo = MailAddress.parseList(h["Reply-To"])
        m.date = DateParsing.rfc2822(h["Date"])
        m.messageId = h["Message-ID"]
        m.references = h["References"]

        var texts: [String] = []
        var htmls: [String] = []
        var inline: [MailAttachment] = []
        var files: [MailAttachment] = []

        func walk(_ p: MIMEPart) {
            if !p.children.isEmpty {
                p.children.forEach(walk)
                return
            }
            let type = p.contentType.value
            let isAttachment = p.disposition.value == "attachment"
            if !isAttachment && p.filename == nil {
                if type == "text/plain" { texts.append(p.text); return }
                if type == "text/html" { htmls.append(p.text); return }
            }
            var name = p.filename ?? ""
            if name.isEmpty { name = defaultName(for: type) }
            let att = MailAttachment(filename: name, mimeType: type, data: p.decodedData, contentId: p.contentId)
            if !isAttachment, p.contentId != nil, type.hasPrefix("image/") {
                inline.append(att)
            } else {
                files.append(att)
            }
        }
        walk(root)

        let joinedText = texts.joined(separator: "\n\n")
        m.text = joinedText.isEmpty ? nil : joinedText
        if !htmls.isEmpty {
            var html = htmls.joined(separator: "<hr>")
            for att in inline {
                guard let cid = att.contentId, !cid.isEmpty else { continue }
                if html.contains("cid:\(cid)") {
                    html = html.replacingOccurrences(of: "cid:\(cid)",
                                                     with: "data:\(att.mimeType);base64,\(att.data.base64EncodedString())")
                } else {
                    files.append(att)
                }
            }
            m.html = html
        } else {
            files.append(contentsOf: inline)
        }
        m.attachments = files
        return m
    }

    private static func defaultName(for type: String) -> String {
        switch type {
        case "message/rfc822": return tr("转发的邮件.eml", "message.eml")
        case "text/calendar": return tr("邀请.ics", "invite.ics")
        case let t where t.hasPrefix("image/"): return tr("图片.", "image.") + (t.split(separator: "/").last.map(String.init) ?? "img")
        default: return tr("附件", "attachment")
        }
    }

    var plainText: String {
        if let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return t.replacingOccurrences(of: "\r\n", with: "\n")
        }
        if let h = html { return HTMLText.plain(h) }
        return ""
    }

    /// 去掉引用的历史内容后的纯文本。
    var newText: String { QuoteStripper.strip(plainText).text }

    /// 列表/折叠卡片里显示的摘要。
    var snippet: String {
        let t = newText.isEmpty ? plainText : newText
        let collapsed = t.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(collapsed.prefix(160))
    }

    var hasRemoteContent: Bool {
        guard let h = html else { return false }
        let patterns = ["src=\"http", "src='http", "src=http", "url(http", "url('http", "url(\"http", "background=\"http"]
        return patterns.contains { h.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// 阅读用的完整 HTML 页面。夜间模式通过 CSS 反色处理 HTML 邮件。
    func renderHTML(allowRemote: Bool, hideQuotes: Bool = false) -> String {
        let csp = allowRemote
            ? "default-src * data: blob: 'unsafe-inline'; script-src 'none';"
            : "default-src 'none'; img-src data: cid:; style-src 'unsafe-inline'; font-src data:;"
        let head = """
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <style>\(Self.css)</style>
        """
        if let html = html {
            return "<!doctype html><html class=\"htmlmail\"><head>\(head)</head><body class=\"html\">\(html)</body></html>"
        }
        var t = plainText
        if hideQuotes {
            let r = QuoteStripper.strip(t)
            if r.stripped { t = r.text }
        }
        let body = HTMLText.escape(t)
        return "<!doctype html><html class=\"plainmail\"><head>\(head)</head><body class=\"plain\"><pre>\(body)</pre></body></html>"
    }

    /// 纯文本邮件里是否有可折叠的引用。
    var plainHasQuote: Bool { html == nil && QuoteStripper.strip(plainText).stripped }

    /// 用于回复/转发时嵌入编辑器的原文 HTML（去掉脚本、样式表等）。
    var quotableHTML: String {
        if let h = html { return HTMLText.sanitizeForQuote(h) }
        return HTMLText.escape(plainText).replacingOccurrences(of: "\n", with: "<br>")
    }

    private static let css = """
    html { -webkit-text-size-adjust: 100%; }
    html, body { height: auto !important; min-height: 0 !important; }
    body { margin: 12px; color: #000; background: #fff; font: 16px Helvetica, "PingFang SC", sans-serif; overflow-wrap: anywhere; word-wrap: break-word; }
    body.plain pre { white-space: pre-wrap; margin: 0; font: 16px Helvetica, "PingFang SC", sans-serif; line-height: 1.4; }
    body.plain a { color: #000; }
    img { max-width: 100% !important; height: auto !important; }
    blockquote { margin: 0 0 0 4px; padding-left: 8px; border-left: 2px solid #888; }
    @media (prefers-color-scheme: dark) {
      html.plainmail, body.plain { background: #121212; color: #e9e9e9; }
      body.plain a { color: #e9e9e9; }
      html.htmlmail { filter: invert(1) hue-rotate(180deg); background: #fff; }
      html.htmlmail img, html.htmlmail video, html.htmlmail picture, html.htmlmail [style*="background-image"] { filter: invert(1) hue-rotate(180deg); }
    }
    """
}

/// 从正文开头的一小段数据里提取预览文字（数据可能被截断）。
enum PreviewText {
    static func extract(_ data: Data, contentType: String?, transferEncoding: String?) -> String {
        let ct = HeaderValue.parse(contentType)
        var text = ""
        if ct.value.hasPrefix("multipart/"), let b = ct.params["boundary"], !b.isEmpty {
            text = firstText(in: MIMEPart.splitMultipart(data, boundary: b), depth: 0)
        } else {
            var part = MIMEPart(headers: MIMEHeaders(fields: [("Content-Transfer-Encoding", transferEncoding ?? "")]),
                                body: data, contentType: ct, disposition: HeaderValue(value: "", params: [:]))
            if part.contentType.value.isEmpty { part.contentType.value = "text/plain" }
            text = render(part)
        }
        return clean(text)
    }

    private static func firstText(in parts: [Data], depth: Int) -> String {
        guard depth < 6 else { return "" }
        var html: MIMEPart?
        for raw in parts {
            let p = MIMEPart.parse(raw, depth: depth + 1)
            let t = p.contentType.value
            if t.hasPrefix("multipart/"), let b = p.contentType.params["boundary"] {
                let inner = firstText(in: MIMEPart.splitMultipart(p.body, boundary: b), depth: depth + 1)
                if !inner.isEmpty { return inner }
            } else if t == "text/plain" && p.disposition.value != "attachment" {
                return render(p)
            } else if t == "text/html" && html == nil {
                html = p
            }
        }
        if let h = html { return render(h) }
        return ""
    }

    private static func render(_ p: MIMEPart) -> String {
        var data = p.decodedData
        // 截断的 UTF-8 末尾可能是半个字符
        for _ in 0..<3 {
            if String(data: data, encoding: .utf8) != nil || data.isEmpty { break }
            data.removeLast()
        }
        let s = Charset.decode(data, charset: p.contentType.params["charset"])
        return p.contentType.value == "text/html" ? HTMLText.plain(s) : s
    }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n")
        t = QuoteStripper.strip(t).text
        let lines = t.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
        let collapsed = lines.joined(separator: " ")
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(collapsed.prefix(200))
    }
}

/// 识别并去掉回复邮件里引用的旧内容（各家客户端的分隔格式）。
enum QuoteStripper {
    private static let markers: [NSRegularExpression] = [
        "^-{2,}\\s*(original message|原始邮件|原始郵件|original|forwarded message|转发的邮件|轉寄的郵件|回复的邮件)\\s*-{2,}",
        "^-{5,}\\s*$",
        "^_{10,}\\s*$",
        "^在.{2,80}写道[:：]\\s*$",
        "^在.{2,80}寫道[:：]\\s*$",
        "^on .{4,160} wrote:\\s*$",
        "^(发件人|寄件者|from)[:：]\\s*.+",
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func strip(_ text: String) -> (text: String, stripped: Bool) {
        let lines = text.components(separatedBy: "\n")
        var cut: Int?
        for (i, raw) in lines.enumerated() {
            let line = raw.replacingOccurrences(of: "\u{00a0}", with: " ").trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            var hit = markers.contains { $0.firstMatch(in: line, range: range) != nil }
            if hit, line.lowercased().hasPrefix("from") || line.hasPrefix("发件人") || line.hasPrefix("寄件者") {
                // “发件人：”必须紧跟着“发送时间/日期/Sent/Date”才算引用头
                let next = lines.dropFirst(i + 1).prefix(3).joined(separator: " ").lowercased()
                hit = next.contains("sent") || next.contains("date") || next.contains("发送时间") || next.contains("日期") || next.contains("時間")
            }
            if !hit && line.hasPrefix(">") {
                // 连续以 > 开头直到结尾
                let rest = lines.dropFirst(i).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                hit = rest.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            }
            if hit {
                cut = i
                break
            }
        }
        guard let c = cut, c > 0 else { return (text, false) }
        let kept = lines[0..<c].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if kept.isEmpty { return (text, false) }
        return (kept, true)
    }
}

// MARK: - HTML 辅助

enum HTMLText {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 引用原文时清理 HTML：去掉 head/style/script，只保留正文内容。
    static func sanitizeForQuote(_ html: String) -> String {
        var s = html
        for tag in ["script", "style", "head", "title", "xml", "o:p"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "",
                                       options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "</?(html|body|meta|link|base)[^>]*>", with: "",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<!doctype[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "\\son[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*')", with: "",
                                   options: [.regularExpression, .caseInsensitive])
        return s
    }

    private static let entityRegex = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")

    static func plain(_ html: String) -> String {
        var s = html
        for tag in ["style", "script", "head", "title"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "",
                                       options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</(p|div|tr|li|h[1-6]|blockquote|table)>", with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities: [(String, String)] = [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                            ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")]
        for (k, v) in entities {
            s = s.replacingOccurrences(of: k, with: v, options: .caseInsensitive)
        }
        let ns = s as NSString
        let matches = entityRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var out = s
        for m in matches.reversed() {
            let isHex = ns.substring(with: m.range(at: 1)) == "x"
            let num = ns.substring(with: m.range(at: 2))
            if let v = UInt32(num, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(v),
               let r = Range(m.range, in: out) {
                out.replaceSubrange(r, with: String(Character(scalar)))
            }
        }
        out = out.replacingOccurrences(of: "[ \t]+\n", with: "\n", options: .regularExpression)
        out = out.replacingOccurrences(of: "\n[ \t]+", with: "\n", options: .regularExpression)
        out = out.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
