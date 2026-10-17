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

struct OutgoingMail {
    var from: MailAddress
    var to: [MailAddress]
    var cc: [MailAddress]
    var bcc: [MailAddress]
    var subject: String
    var body: String
    var attachments: [OutgoingAttachment]
    var inReplyTo: String?
    var references: String?

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
        add("MIME-Version", "1.0")
        add("X-Mailer", "RetroMail 1.0 (iOS)")

        let normalized = mail.body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let bodyB64 = Data(normalized.utf8).base64EncodedString(options: b64Options)

        var out = Data()
        if mail.attachments.isEmpty {
            add("Content-Type", "text/plain; charset=UTF-8")
            add("Content-Transfer-Encoding", "base64")
            out.append(Data((h + "\r\n" + bodyB64 + "\r\n").utf8))
            return out
        }

        let boundary = "----=_RetroMail_\(UUID().uuidString)"
        add("Content-Type", "multipart/mixed; boundary=\"\(boundary)\"")
        var head = h + "\r\nThis is a multi-part message in MIME format.\r\n"
        head += "--\(boundary)\r\n"
        head += "Content-Type: text/plain; charset=UTF-8\r\n"
        head += "Content-Transfer-Encoding: base64\r\n\r\n"
        head += bodyB64 + "\r\n"
        out.append(Data(head.utf8))

        for a in mail.attachments {
            let safe = a.filename.replacingOccurrences(of: "\"", with: "'")
            let n = HeaderCoding.encode(safe, fold: false)
            var part = "--\(boundary)\r\n"
            part += "Content-Type: \(a.mimeType); name=\"\(n)\"\r\n"
            part += "Content-Disposition: attachment; filename=\"\(n)\"\r\n"
            part += "Content-Transfer-Encoding: base64\r\n\r\n"
            out.append(Data(part.utf8))
            out.append(Data(a.data.base64EncodedString(options: b64Options).utf8))
            out.append(Data("\r\n".utf8))
        }
        out.append(Data("--\(boundary)--\r\n".utf8))
        return out
    }
}
