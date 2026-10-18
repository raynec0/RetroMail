import Foundation
import UIKit
import UniformTypeIdentifiers

/// 把离线缓存（下载过的邮件原文，含附件）转存到 iCloud 云盘或“文件”里的任意文件夹，腾出本机空间。
///
/// 自签安装的应用拿不到 iCloud 容器权限，所以这里让你在“文件”里选一个文件夹（推荐 iCloud 云盘），
/// 应用用系统给的安全书签访问它。转存后的邮件仍然可以离线打开：本机找不到时会去这个文件夹里读，
/// 读不到（例如 iCloud 还没下载下来）再从邮件服务器重新下载。
enum CacheArchive {
    private static let bookmarkKey = "cache.archive.bookmark"
    private static let autoKey = "cache.archive.autoDays"
    private static let lastRunKey = "cache.archive.lastRun"
    static let folderName = "RetroMail 邮件存档"

    // MARK: 选的文件夹

    static var isConfigured: Bool { UserDefaults.standard.data(forKey: bookmarkKey) != nil }

    static func setFolder(_ url: URL) throws {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    /// 解析书签，得到用户选的文件夹。
    static func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    static var folderDisplayName: String {
        guard let u = resolveFolder() else { return tr("未选择", "Not set") }
        let path = u.path
        if path.contains("Mobile Documents") { return "iCloud › " + u.lastPathComponent }
        return u.lastPathComponent
    }

    /// 自动转存：超过 N 天未打开的缓存（0 表示关闭）。
    static var autoDays: Int {
        get { UserDefaults.standard.integer(forKey: autoKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    /// 在用户选的文件夹里执行 body（自动处理安全访问）。
    private static func withFolder<T>(_ body: (URL) throws -> T) throws -> T {
        guard let base = resolveFolder() else {
            throw MailError.protocolError(tr("还没有选择存档文件夹。", "No archive folder has been chosen."))
        }
        let ok = base.startAccessingSecurityScopedResource()
        defer { if ok { base.stopAccessingSecurityScopedResource() } }
        let root = base.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return try body(root)
    }

    // MARK: 转存

    struct Result {
        var files = 0
        var bytes = 0
    }

    /// 把本机缓存里的邮件原文复制到存档文件夹，然后删掉本机副本。
    /// olderThanDays = 0 时转存全部。
    static func offload(olderThanDays: Int) throws -> Result {
        let local = DiskCache.rawFiles()
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86400)
        let fm = FileManager.default
        var result = Result()
        try withFolder { root -> Void in
            let coordinator = NSFileCoordinator()
            for f in local {
                let values = try? f.url.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey, .fileSizeKey])
                let used = values?.contentAccessDate ?? values?.contentModificationDate ?? Date.distantPast
                if olderThanDays > 0 && used > cutoff { continue }
                let dir = root.appendingPathComponent(f.account, isDirectory: true)
                if !fm.fileExists(atPath: dir.path) { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
                let dest = dir.appendingPathComponent(f.name + ".eml")
                var writeError: Error?
                var coordError: NSError?
                coordinator.coordinate(writingItemAt: dest, options: .forReplacing, error: &coordError) { target in
                    do {
                        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                        try fm.copyItem(at: f.url, to: target)
                    } catch {
                        writeError = error
                    }
                }
                if let e = writeError ?? coordError { throw e }
                result.files += 1
                result.bytes += values?.fileSize ?? 0
                try? fm.removeItem(at: f.url)
            }
        }
        UserDefaults.standard.set(Date(), forKey: lastRunKey)
        return result
    }

    /// 打开邮件时本机没有缓存：到存档里找。
    static func load(account: UUID, name: String) -> Data? {
        guard isConfigured else { return nil }
        let found: Data?? = try? withFolder { root -> Data? in
            let url = root.appendingPathComponent(account.uuidString, isDirectory: true).appendingPathComponent(name + ".eml")
            guard FileManager.default.fileExists(atPath: url.path) || isPlaceholder(url) else { return nil }
            var data: Data?
            var err: NSError?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
                data = try? Data(contentsOf: u)
            }
            if data == nil { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
            return data
        }
        return found ?? nil
    }

    private static func isPlaceholder(_ url: URL) -> Bool {
        let p = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        return FileManager.default.fileExists(atPath: p.path)
    }

    /// 存档里的邮件数和大小。
    static func stats() -> (files: Int, bytes: Int)? {
        guard isConfigured else { return nil }
        return try? withFolder { root -> (files: Int, bytes: Int) in
            var n = 0, total = 0
            if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in e where url.pathExtension == "eml" || url.lastPathComponent.hasSuffix(".eml.icloud") {
                    n += 1
                    total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                }
            }
            return (n, total)
        }
    }

    /// 删除存档里的全部邮件（服务器上的邮件不受影响）。
    static func clearArchive() throws {
        try withFolder { root -> Void in
            for item in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                try FileManager.default.removeItem(at: item)
            }
        }
    }

    /// 启动时：每天最多一次，自动转存旧缓存。
    static func autoRunIfNeeded() async {
        let days = autoDays
        guard days > 0, isConfigured else { return }
        if let last = UserDefaults.standard.object(forKey: lastRunKey) as? Date, Date().timeIntervalSince(last) < 86400 { return }
        _ = await Task.detached(priority: .background) { try? offload(olderThanDays: days) }.value
    }
}

extension DiskCache {
    struct RawFile {
        let account: String
        let name: String
        let url: URL
    }

    /// 本机缓存里所有的邮件原文文件。
    static func rawFiles() -> [RawFile] {
        let fm = FileManager.default
        var out: [RawFile] = []
        guard let accounts = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        for dir in accounts where UUID(uuidString: dir.lastPathComponent) != nil {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where isRawName(f.lastPathComponent) {
                out.append(RawFile(account: dir.lastPathComponent, name: f.lastPathComponent, url: f))
            }
        }
        return out
    }

    private static func isRawName(_ name: String) -> Bool {
        var b64 = name.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let d = Data(base64Encoded: b64), let s = String(data: d, encoding: .utf8) else { return false }
        return s.hasPrefix("raw\u{1}")
    }

    static var rawSize: Int {
        rawFiles().reduce(0) { $0 + ((try? $1.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

/// 在“文件”里选一个文件夹。
struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        vc.allowsMultipleSelection = false
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(_ onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { onPick(u) }
        }
    }
}
