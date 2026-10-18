import Foundation

// MARK: - 附件类型

enum AttachmentKind {
    case email, calendar, image, other

    static func of(_ a: MailAttachment) -> AttachmentKind {
        let t = a.mimeType.lowercased()
        let ext = (a.filename as NSString).pathExtension.lowercased()
        if t == "message/rfc822" || ext == "eml" { return .email }
        if t == "text/calendar" || t == "application/ics" || ext == "ics" || ext == "vcs" { return .calendar }
        if t.hasPrefix("image/") { return .image }
        return .other
    }
}

// MARK: - 显示数据：在后台一次算好，界面只读（避免卡顿）

/// 一封邮件显示时需要的全部结果。引用类型：在数组里复制时不复制大字符串。
final class MessageDisplay {
    let parsed: ParsedMessage
    let snippet: String
    let newText: String
    let hasRemote: Bool
    let plainHasQuote: Bool
    /// 附件里的会议邀请（显示在正文上方）
    let invites: [(event: CalendarEvent, attachment: MailAttachment)]
    private let pages: [String]

    private init(parsed: ParsedMessage) {
        self.parsed = parsed
        let plain = parsed.plainText
        let stripped = QuoteStripper.strip(plain)
        snippet = PreviewText.clean(plain)
        newText = stripped.text
        hasRemote = parsed.hasRemoteContent
        plainHasQuote = parsed.html == nil && stripped.stripped
        // [远程图片否/是] × [折叠引用否/是]
        let a = parsed.renderHTML(allowRemote: false, hideQuotes: false)
        let b = parsed.renderHTML(allowRemote: true, hideQuotes: false)
        let c = parsed.html == nil ? parsed.renderHTML(allowRemote: false, hideQuotes: true) : a
        let d = parsed.html == nil ? parsed.renderHTML(allowRemote: true, hideQuotes: true) : b
        pages = [a, b, c, d]
        var inv: [(event: CalendarEvent, attachment: MailAttachment)] = []
        for att in parsed.attachments where AttachmentKind.of(att) == .calendar {
            if let e = ICS.parse(att.data).first { inv.append((e, att)) }
        }
        invites = inv
    }

    func page(remote: Bool, hideQuotes: Bool) -> String {
        pages[(remote ? 1 : 0) + (hideQuotes ? 2 : 0)]
    }

    /// 在后台线程解析并准备显示数据。
    static func make(_ raw: Data) async -> MessageDisplay {
        await Task.detached(priority: .userInitiated) {
            MessageDisplay(parsed: ParsedMessage.parse(raw))
        }.value
    }

    static func make(parsed: ParsedMessage) async -> MessageDisplay {
        await Task.detached(priority: .userInitiated) {
            MessageDisplay(parsed: parsed)
        }.value
    }
}

// MARK: - winmail.dat（TNEF）解包

enum TNEF {
    private static let signature: UInt32 = 0x223E_9F78

    static func isTNEF(_ data: Data, mimeType: String, filename: String) -> Bool {
        let t = mimeType.lowercased()
        let n = filename.lowercased()
        guard t.contains("ms-tnef") || t.contains("vnd.ms-tnef") || n == "winmail.dat" || n.hasSuffix(".dat") else { return false }
        return data.count > 6 && readU32(data, 0) == signature
    }

    private static func readU8(_ d: Data, _ o: Int) -> UInt8? {
        o < d.count ? d[d.startIndex + o] : nil
    }

    private static func readU16(_ d: Data, _ o: Int) -> UInt16? {
        guard o + 2 <= d.count else { return nil }
        let b = d.startIndex + o
        return UInt16(d[b]) | UInt16(d[b + 1]) << 8
    }

    private static func readU32(_ d: Data, _ o: Int) -> UInt32? {
        guard o + 4 <= d.count else { return nil }
        let b = d.startIndex + o
        return UInt32(d[b]) | UInt32(d[b + 1]) << 8 | UInt32(d[b + 2]) << 16 | UInt32(d[b + 3]) << 24
    }

    private static func sub(_ d: Data, _ o: Int, _ n: Int) -> Data? {
        guard o >= 0, n >= 0, o + n <= d.count else { return nil }
        return d.subdata(in: (d.startIndex + o)..<(d.startIndex + o + n))
    }

    private static func cString(_ d: Data) -> String {
        var bytes = [UInt8](d)
        while let l = bytes.last, l == 0 { bytes.removeLast() }
        let data = Data(bytes)
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: Charset.gb18030) ?? String(decoding: data, as: UTF8.self)
    }

    private struct Building {
        var title = ""
        var longName = ""
        var mime = ""
        var data: Data?
    }

    /// 返回 winmail.dat 里的附件；无法解析时返回空数组。
    static func extract(_ d: Data) -> [MailAttachment] {
        guard readU32(d, 0) == signature else { return [] }
        var o = 6
        var out: [MailAttachment] = []
        var cur: Building?

        func flush() {
            guard let c = cur, let data = c.data else { return }
            var name = c.longName.isEmpty ? c.title : c.longName
            if name.isEmpty { name = "attachment\(out.count + 1)" }
            let mime = c.mime.isEmpty ? OutgoingAttachmentMime.guess(name) : c.mime
            out.append(MailAttachment(filename: name, mimeType: mime, data: data, contentId: nil))
        }

        while o + 9 <= d.count {
            guard let level = readU8(d, o), let attr = readU32(d, o + 1), let len32 = readU32(d, o + 5) else { break }
            let len = Int(len32)
            guard let value = sub(d, o + 9, len) else { break }
            o += 9 + len + 2
            guard level == 2 else { continue }
            switch attr {
            case 0x0006_9002: // attAttachRendData：新附件开始
                flush()
                cur = Building()
            case 0x0001_8010: // attAttachTitle
                cur?.title = cString(value)
            case 0x0006_800F: // attAttachData
                cur?.data = value
            case 0x0006_9005: // attAttachment：MAPI 属性（长文件名、MIME 类型）
                let props = mapiStrings(value)
                if let n = props[0x3707] { cur?.longName = n }
                if let m = props[0x370E] { cur?.mime = m }
            default:
                break
            }
        }
        flush()
        return out
    }

    /// 只取出字符串类型的 MAPI 属性：属性 ID -> 值。
    private static func mapiStrings(_ d: Data) -> [UInt16: String] {
        var out: [UInt16: String] = [:]
        guard let count = readU32(d, 0) else { return out }
        var o = 4
        func pad(_ n: Int) -> Int { (n + 3) & ~3 }
        for _ in 0..<min(Int(count), 500) {
            guard let type = readU16(d, o), let id = readU16(d, o + 2) else { break }
            o += 4
            if id >= 0x8000 { // 命名属性
                o += 16
                guard let kind = readU32(d, o) else { break }
                o += 4
                if kind == 0 {
                    o += 4
                } else {
                    guard let nl = readU32(d, o) else { break }
                    o += 4 + pad(Int(nl))
                }
            }
            let multi = type & 0x1000 != 0
            let base = type & 0x0FFF
            var n = 1
            if multi {
                guard let c = readU32(d, o) else { return out }
                n = Int(c)
                o += 4
            }
            let fixed: [UInt16: Int] = [0x0002: 4, 0x0003: 4, 0x0004: 4, 0x000A: 4, 0x000B: 4,
                                        0x0005: 8, 0x0006: 8, 0x0007: 8, 0x0014: 8, 0x0040: 8, 0x0048: 16]
            if let size = fixed[base] {
                o += size * n
                continue
            }
            guard [0x001E, 0x001F, 0x0102, 0x000D].contains(base) else { return out }
            if !multi {
                guard let c = readU32(d, o) else { return out }
                n = Int(c)
                o += 4
            }
            for _ in 0..<min(n, 1000) {
                guard let l = readU32(d, o), let v = sub(d, o + 4, Int(l)) else { return out }
                o += 4 + pad(Int(l))
                if base == 0x001E {
                    out[id] = cString(v)
                } else if base == 0x001F {
                    var s = String(data: v, encoding: .utf16LittleEndian) ?? ""
                    while s.hasSuffix("\u{0}") { s.removeLast() }
                    out[id] = s
                }
            }
        }
        return out
    }
}

enum OutgoingAttachmentMime {
    static func guess(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "txt": return "text/plain"
        case "zip": return "application/zip"
        case "eml": return "message/rfc822"
        case "ics": return "text/calendar"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - 会议邀请（iCalendar）

struct CalendarAttendee: Hashable {
    var name: String
    var email: String
    var status: String // NEEDS-ACTION / ACCEPTED / DECLINED / TENTATIVE
    var role: String

    var display: String { name.isEmpty ? email : name }

    var statusLabel: String {
        switch status.uppercased() {
        case "ACCEPTED": return tr("已接受", "Accepted")
        case "DECLINED": return tr("已拒绝", "Declined")
        case "TENTATIVE": return tr("暂定", "Tentative")
        case "DELEGATED": return tr("已委托", "Delegated")
        default: return tr("未回复", "No response")
        }
    }
}

struct CalendarEvent {
    var method = ""
    var uid = ""
    var summary = ""
    var location = ""
    var description = ""
    var start: Date?
    var end: Date?
    var allDay = false
    var organizerName = ""
    var organizerEmail = ""
    var attendees: [CalendarAttendee] = []
    var status = ""
    var recurrence = ""
    /// 原始属性行（回复时原样带回）
    var rawLines: [String: String] = [:]
    var timezoneBlocks: [String] = []

    var isCancelled: Bool { method.uppercased() == "CANCEL" || status.uppercased() == "CANCELLED" }
    var isRequest: Bool { method.isEmpty || method.uppercased() == "REQUEST" }

    var timeText: String {
        guard let s = start else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: tr("zh_CN", "en_US"))
        if allDay {
            f.dateFormat = tr("yyyy年M月d日 EEE", "EEE, MMM d, yyyy")
            var t = f.string(from: s)
            if let e = end, let last = Calendar.current.date(byAdding: .day, value: -1, to: e),
               !Calendar.current.isDate(last, inSameDayAs: s) {
                t += " – " + f.string(from: last)
            }
            return t + tr("（全天）", " (all day)")
        }
        f.dateFormat = tr("yyyy年M月d日 EEE HH:mm", "EEE, MMM d, yyyy h:mm a")
        var t = f.string(from: s)
        if let e = end {
            let g = DateFormatter()
            g.locale = f.locale
            g.dateFormat = Calendar.current.isDate(e, inSameDayAs: s) ? tr("HH:mm", "h:mm a") : f.dateFormat
            t += " – " + g.string(from: e)
        }
        return t
    }

    func attendee(_ email: String) -> CalendarAttendee? {
        attendees.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }
    }
}

enum ICS {
    /// 展开折行，按 BEGIN/END 拆出事件。
    static func parse(_ data: Data) -> [CalendarEvent] {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: Charset.gb18030) ?? String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if let f = raw.first, f == " " || f == "\t", !lines.isEmpty {
                lines[lines.count - 1] += String(raw.dropFirst())
            } else if !raw.isEmpty {
                lines.append(raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            }
        }

        var method = ""
        var tzBlocks: [String] = []
        var tzOffsets: [String: Int] = [:]
        var events: [CalendarEvent] = []
        var cur: CalendarEvent?
        var inTZ = false
        var tzLines: [String] = []
        var tzId = ""
        var tzSection = ""
        var depth: [String] = []

        for line in lines {
            let (name, params, value) = split(line)
            if name == "BEGIN" {
                depth.append(value.uppercased())
                if value.uppercased() == "VEVENT" && depth.count <= 2 {
                    cur = CalendarEvent()
                } else if value.uppercased() == "VTIMEZONE" {
                    inTZ = true
                    tzLines = [line]
                    tzId = ""
                } else if inTZ {
                    tzLines.append(line)
                    tzSection = value.uppercased()
                }
                continue
            }
            if name == "END" {
                _ = depth.popLast()
                if value.uppercased() == "VEVENT", var e = cur, depth.count <= 1 {
                    e.method = method
                    events.append(e)
                    cur = nil
                } else if value.uppercased() == "VTIMEZONE" {
                    tzLines.append(line)
                    tzBlocks.append(tzLines.joined(separator: "\r\n"))
                    inTZ = false
                } else if inTZ {
                    tzLines.append(line)
                    tzSection = ""
                }
                continue
            }
            if inTZ {
                tzLines.append(line)
                if name == "TZID" { tzId = value }
                if name == "TZOFFSETTO", tzSection == "STANDARD", let off = parseOffset(value) { tzOffsets[tzId] = off }
                continue
            }
            if depth.last == "VCALENDAR" && name == "METHOD" {
                method = value
                continue
            }
            guard cur != nil, depth.last == "VEVENT" else { continue }
            switch name {
            case "UID": cur!.uid = value
            case "SUMMARY": cur!.summary = unescape(value)
            case "LOCATION": cur!.location = unescape(value)
            case "DESCRIPTION": cur!.description = unescape(value)
            case "STATUS": cur!.status = value
            case "RRULE": cur!.recurrence = value
            case "DTSTART":
                let (d, allDay) = parseDate(value, params: params, offsets: tzOffsets)
                cur!.start = d
                cur!.allDay = allDay
            case "DTEND":
                cur!.end = parseDate(value, params: params, offsets: tzOffsets).0
            case "DURATION":
                if let s = cur!.start, let secs = parseDuration(value) { cur!.end = s.addingTimeInterval(secs) }
            case "ORGANIZER":
                cur!.organizerName = unquote(params["CN"] ?? "")
                cur!.organizerEmail = mailto(value)
            case "ATTENDEE":
                cur!.attendees.append(CalendarAttendee(name: unquote(params["CN"] ?? ""), email: mailto(value),
                                                       status: params["PARTSTAT"] ?? "NEEDS-ACTION", role: params["ROLE"] ?? ""))
            default:
                break
            }
            if ["DTSTART", "DTEND", "DURATION", "RECURRENCE-ID", "SEQUENCE", "SUMMARY", "ORGANIZER", "UID", "LOCATION"].contains(name) {
                cur!.rawLines[name] = line
            }
        }
        // 时区块对所有事件都可用
        return events.map { var e = $0; e.timezoneBlocks = tzBlocks; return e }
    }

    static func split(_ line: String) -> (String, [String: String], String) {
        // 找到第一个不在引号内的冒号
        var inQuote = false
        var colon: String.Index?
        for i in line.indices {
            let c = line[i]
            if c == "\"" { inQuote.toggle() }
            if c == ":" && !inQuote {
                colon = i
                break
            }
        }
        guard let ci = colon else { return (line.uppercased(), [:], "") }
        let head = String(line[..<ci])
        let value = String(line[line.index(after: ci)...])
        var parts: [String] = []
        var cur = ""
        inQuote = false
        for c in head {
            if c == "\"" { inQuote.toggle() }
            if c == ";" && !inQuote {
                parts.append(cur)
                cur = ""
            } else {
                cur.append(c)
            }
        }
        parts.append(cur)
        var params: [String: String] = [:]
        for p in parts.dropFirst() {
            if let eq = p.firstIndex(of: "=") {
                params[String(p[..<eq]).uppercased()] = String(p[p.index(after: eq)...])
            }
        }
        return ((parts.first ?? "").uppercased(), params, value)
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            if c == "\\", let n = it.next() {
                switch n {
                case "n", "N": out.append("\n")
                default: out.append(n)
                }
            } else {
                out.append(c)
            }
        }
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func unquote(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func mailto(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        if v.lowercased().hasPrefix("mailto:") { v = String(v.dropFirst(7)) }
        return v
    }

    static func parseOffset(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 5, let sign = t.first, sign == "+" || sign == "-" else { return nil }
        let digits = Array(t.dropFirst())
        guard digits.count >= 4, let h = Int(String(digits[0..<2])), let m = Int(String(digits[2..<4])) else { return nil }
        let v = h * 3600 + m * 60
        return sign == "-" ? -v : v
    }

    private static func parseDuration(_ s: String) -> TimeInterval? {
        // P1DT2H30M / PT45M / P1W
        var total: TimeInterval = 0
        var num = ""
        var neg = false
        for c in s.uppercased() {
            if c == "-" { neg = true; continue }
            if c.isNumber { num.append(c); continue }
            let n = Double(num) ?? 0
            switch c {
            case "W": total += n * 7 * 86400
            case "D": total += n * 86400
            case "H": total += n * 3600
            case "M": total += n * 60
            case "S": total += n
            default: break
            }
            num = ""
        }
        return total == 0 ? nil : (neg ? -total : total)
    }

    /// Outlook 常用的 Windows 时区名 → IANA
    static let windowsZones: [String: String] = [
        "china standard time": "Asia/Shanghai", "taipei standard time": "Asia/Taipei",
        "singapore standard time": "Asia/Singapore", "malay peninsula standard time": "Asia/Kuala_Lumpur",
        "tokyo standard time": "Asia/Tokyo", "korea standard time": "Asia/Seoul",
        "india standard time": "Asia/Kolkata", "se asia standard time": "Asia/Bangkok",
        "arabian standard time": "Asia/Dubai", "arab standard time": "Asia/Riyadh", "arabic standard time": "Asia/Baghdad",
        "iran standard time": "Asia/Tehran", "pakistan standard time": "Asia/Karachi", "bangladesh standard time": "Asia/Dhaka",
        "west asia standard time": "Asia/Tashkent", "north asia east standard time": "Asia/Irkutsk", "n. asia standard time": "Asia/Novosibirsk",
        "russian standard time": "Europe/Moscow", "gmt standard time": "Europe/London", "greenwich standard time": "Atlantic/Reykjavik",
        "w. europe standard time": "Europe/Berlin", "romance standard time": "Europe/Paris",
        "central europe standard time": "Europe/Budapest", "central european standard time": "Europe/Warsaw",
        "e. europe standard time": "Europe/Chisinau", "gtb standard time": "Europe/Bucharest", "fle standard time": "Europe/Kiev",
        "turkey standard time": "Europe/Istanbul", "egypt standard time": "Africa/Cairo", "south africa standard time": "Africa/Johannesburg",
        "w. central africa standard time": "Africa/Lagos", "e. africa standard time": "Africa/Nairobi",
        "eastern standard time": "America/New_York", "central standard time": "America/Chicago",
        "mountain standard time": "America/Denver", "pacific standard time": "America/Los_Angeles",
        "alaskan standard time": "America/Anchorage", "hawaiian standard time": "Pacific/Honolulu",
        "atlantic standard time": "America/Halifax", "e. south america standard time": "America/Sao_Paulo",
        "sa pacific standard time": "America/Bogota", "argentina standard time": "America/Buenos_Aires",
        "aus eastern standard time": "Australia/Sydney", "e. australia standard time": "Australia/Brisbane",
        "w. australia standard time": "Australia/Perth", "cen. australia standard time": "Australia/Adelaide",
        "new zealand standard time": "Pacific/Auckland", "utc": "UTC", "coordinated universal time": "UTC",
    ]

    static func timeZone(_ tzid: String?, offsets: [String: Int]) -> TimeZone {
        guard var id = tzid?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")), !id.isEmpty else { return .current }
        if id.hasPrefix("/") { id = String(id.drop { $0 == "/" }) }
        if let tz = TimeZone(identifier: id) { return tz }
        if let iana = windowsZones[id.lowercased()], let tz = TimeZone(identifier: iana) { return tz }
        // “(UTC+08:00) Beijing, …” 这类写法
        if let r = id.range(of: "(UTC|GMT)\\s*[+-]\\d{1,2}:?\\d{2}", options: .regularExpression) {
            let s = id[r].replacingOccurrences(of: "UTC", with: "").replacingOccurrences(of: "GMT", with: "")
                .replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
            let sign = s.first == "-" ? -1 : 1
            let digits = s.dropFirst()
            let padded = digits.count == 3 ? "0" + digits : String(digits)
            if let h = Int(padded.prefix(2)), let m = Int(padded.suffix(2)),
               let tz = TimeZone(secondsFromGMT: sign * (h * 3600 + m * 60)) {
                return tz
            }
        }
        if let off = offsets[id], let tz = TimeZone(secondsFromGMT: off) { return tz }
        return .current
    }

    static func parseDate(_ value: String, params: [String: String], offsets: [String: Int]) -> (Date?, Bool) {
        let v = value.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if params["VALUE"]?.uppercased() == "DATE" || (v.count == 8 && !v.contains("T")) {
            f.dateFormat = "yyyyMMdd"
            f.timeZone = .current
            return (f.date(from: String(v.prefix(8))), true)
        }
        if v.hasSuffix("Z") {
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            return (f.date(from: v), false)
        }
        f.timeZone = timeZone(params["TZID"], offsets: offsets)
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return (f.date(from: String(v.prefix(15))), false)
    }

    // MARK: 回复（iMIP REPLY）

    static func fold(_ line: String) -> String {
        var out = ""
        var count = 0
        for ch in line {
            let n = String(ch).utf8.count
            if count + n > 74 {
                out += "\r\n "
                count = 1
            }
            out.append(ch)
            count += n
        }
        return out
    }

    /// 生成接受/暂定/拒绝的回复日历。partstat: ACCEPTED / TENTATIVE / DECLINED
    static func reply(to e: CalendarEvent, me: MailAddress, partstat: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var lines = ["BEGIN:VCALENDAR", "PRODID:-//RetroMail//iOS//EN", "VERSION:2.0", "METHOD:REPLY"]
        lines += e.timezoneBlocks.flatMap { $0.components(separatedBy: "\r\n") }
        lines.append("BEGIN:VEVENT")
        for key in ["UID", "RECURRENCE-ID", "SEQUENCE", "DTSTART", "DTEND", "DURATION", "SUMMARY", "LOCATION", "ORGANIZER"] {
            if let l = e.rawLines[key] { lines.append(l) }
        }
        if e.rawLines["UID"] == nil { lines.append("UID:" + e.uid) }
        lines.append("DTSTAMP:" + f.string(from: Date()))
        let cn = me.name.isEmpty ? "" : ";CN=\"\(me.name.replacingOccurrences(of: "\"", with: ""))\""
        lines.append("ATTENDEE;PARTSTAT=\(partstat)\(cn):mailto:\(me.email)")
        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }
}
