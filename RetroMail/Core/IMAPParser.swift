import Foundation

/// IMAP 响应中的一个值：原子、字符串（引号或字面量）或括号列表。
enum IMAPValue {
    case atom(String)
    case string(Data)
    case list([IMAPValue])

    var string: String? {
        switch self {
        case .atom(let a):
            return a.uppercased() == "NIL" ? nil : a
        case .string(let d):
            return String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
        case .list:
            return nil
        }
    }

    var data: Data? {
        switch self {
        case .string(let d): return d
        case .atom(let a): return a.uppercased() == "NIL" ? nil : Data(a.utf8)
        case .list: return nil
        }
    }

    var list: [IMAPValue]? {
        if case .list(let l) = self { return l }
        return nil
    }
}

struct IMAPParser {
    private let b: [UInt8]
    private var i = 0

    private init(_ data: Data) {
        b = [UInt8](data)
    }

    static func parse(_ data: Data) -> [IMAPValue] {
        var p = IMAPParser(data)
        return p.parseSequence(closing: false)
    }

    private mutating func parseSequence(closing: Bool) -> [IMAPValue] {
        var out: [IMAPValue] = []
        while i < b.count {
            let c = b[i]
            if c == 32 || c == 13 || c == 10 {
                i += 1
                continue
            }
            if c == 41 { // )
                i += 1
                if closing { return out }
                continue
            }
            if c == 40 { // (
                i += 1
                out.append(.list(parseSequence(closing: true)))
                continue
            }
            if c == 34 { // "
                out.append(.string(parseQuoted()))
                continue
            }
            if c == 123, let lit = parseLiteral() { // {
                out.append(.string(lit))
                continue
            }
            out.append(.atom(parseAtom()))
        }
        return out
    }

    private mutating func parseQuoted() -> Data {
        i += 1
        var d = Data()
        while i < b.count {
            let c = b[i]
            if c == 92, i + 1 < b.count { // backslash
                d.append(b[i + 1])
                i += 2
                continue
            }
            if c == 34 {
                i += 1
                break
            }
            d.append(c)
            i += 1
        }
        return d
    }

    private mutating func parseLiteral() -> Data? {
        var j = i + 1
        var n = 0
        var digits = 0
        while j < b.count, b[j] >= 48, b[j] <= 57 {
            n = n * 10 + Int(b[j] - 48)
            j += 1
            digits += 1
        }
        if j < b.count, b[j] == 43 { j += 1 } // LITERAL+
        guard digits > 0, j < b.count, b[j] == 125 else { return nil }
        j += 1
        if j < b.count, b[j] == 13 { j += 1 }
        if j < b.count, b[j] == 10 { j += 1 }
        let end = min(b.count, j + n)
        let d = Data(b[j..<end])
        i = end
        return d
    }

    private mutating func parseAtom() -> String {
        var d: [UInt8] = []
        var depth = 0
        while i < b.count {
            let c = b[i]
            if depth == 0 && (c == 32 || c == 40 || c == 41 || c == 13 || c == 10) { break }
            if c == 91 {
                depth += 1
            } else if c == 93 && depth > 0 {
                depth -= 1
            }
            d.append(c)
            i += 1
        }
        if d.isEmpty {
            i += 1
            return ""
        }
        return String(decoding: d, as: UTF8.self)
    }
}

/// IMAP 文件夹名使用的“修改版 UTF-7”（RFC 3501 §5.1.3）。
enum IMAPUTF7 {
    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&" {
                guard let end = s[i...].firstIndex(of: "-") else {
                    out += s[i...]
                    break
                }
                let b64 = s[s.index(after: i)..<end]
                if b64.isEmpty {
                    out += "&"
                } else {
                    var std = b64.replacingOccurrences(of: ",", with: "/")
                    while std.count % 4 != 0 { std += "=" }
                    if let d = Data(base64Encoded: std), let str = String(data: d, encoding: .utf16BigEndian) {
                        out += str
                    } else {
                        out += s[i...end]
                    }
                }
                i = s.index(after: end)
            } else {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }

    static func encode(_ s: String) -> String {
        var out = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            var d = Data()
            for u in pending {
                d.append(UInt8(u >> 8))
                d.append(UInt8(u & 0xff))
            }
            var b = d.base64EncodedString().replacingOccurrences(of: "/", with: ",")
            while b.hasSuffix("=") { b.removeLast() }
            out += "&" + b + "-"
            pending = []
        }
        for scalar in s.unicodeScalars {
            if scalar.value >= 0x20 && scalar.value <= 0x7e {
                flush()
                if scalar == "&" {
                    out += "&-"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            } else {
                pending.append(contentsOf: Array(String(scalar).utf16))
            }
        }
        flush()
        return out
    }
}
