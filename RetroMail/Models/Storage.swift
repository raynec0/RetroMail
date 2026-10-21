import Foundation
import Security

// MARK: - 钥匙串（存密码）

enum Keychain {
    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "RetroMail",
         kSecAttrAccount as String: key]
    }

    static func set(_ value: String, for key: String) {
        SecItemDelete(base(key) as CFDictionary)
        var add = base(key)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        // 个别自签环境钥匙串不可用时退回到本机存储。
        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: "pw." + key)
        } else {
            UserDefaults.standard.set(value, forKey: "pw." + key)
        }
    }

    static func get(_ key: String) -> String? {
        var q = base(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
            return String(data: d, encoding: .utf8)
        }
        return UserDefaults.standard.string(forKey: "pw." + key)
    }

    static func delete(_ key: String) {
        SecItemDelete(base(key) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "pw." + key)
    }
}

// MARK: - 账户列表

@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()
    private static let key = "accounts.v1"

    @Published private(set) var accounts: [MailAccount] = []

    private init() {
        accounts = Self.loadFromDisk()
    }

    nonisolated static func loadFromDisk() -> [MailAccount] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([MailAccount].self, from: d) else { return [] }
        return list
    }

    func save(_ account: MailAccount, imapPassword: String, smtpPassword: String) {
        Keychain.set(imapPassword, for: account.imapKey)
        if account.smtpSameAuth {
            Keychain.delete(account.smtpKey)
        } else {
            Keychain.set(smtpPassword, for: account.smtpKey)
        }
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[i] = account
        } else {
            accounts.append(account)
        }
        persist()
    }

    func delete(_ account: MailAccount) {
        Keychain.delete(account.imapKey)
        Keychain.delete(account.smtpKey)
        accounts.removeAll { $0.id == account.id }
        persist()
        DiskCache.removeAccount(account.id)
    }

    func account(_ id: UUID) -> MailAccount? {
        accounts.first { $0.id == id }
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(d, forKey: Self.key)
        }
    }
}

// MARK: - 磁盘缓存（离线浏览）

enum DiskCache {
    static var root: URL {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RetroMail", isDirectory: true)
        if !FileManager.default.fileExists(atPath: u.path) {
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        }
        return u
    }

    private static func fileName(_ parts: [String]) -> String {
        Data(parts.joined(separator: "\u{1}").utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func dir(_ account: UUID) -> URL {
        let u = root.appendingPathComponent(account.uuidString, isDirectory: true)
        if !FileManager.default.fileExists(atPath: u.path) {
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        }
        return u
    }

    /// 磁盘写入都放到这条后台队列上，不占主线程（避免卡顿和被系统看门狗杀掉）
    static let io = DispatchQueue(label: "retromail.disk", qos: .utility)

    static func saveList(_ list: [MessageSummary], account: UUID, folder: String) {
        let url = dir(account).appendingPathComponent(fileName(["list", folder]))
        io.async {
            guard let d = try? JSONEncoder().encode(list) else { return }
            try? d.write(to: url, options: .atomic)
        }
    }

    static func loadList(account: UUID, folder: String) -> [MessageSummary] {
        let url = dir(account).appendingPathComponent(fileName(["list", folder]))
        guard let d = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([MessageSummary].self, from: d) else { return [] }
        return list
    }

    static func saveFolders(_ list: [MailFolder], account: UUID) {
        let url = dir(account).appendingPathComponent("folders.json")
        io.async {
            guard let d = try? JSONEncoder().encode(list) else { return }
            try? d.write(to: url, options: .atomic)
        }
    }

    static func loadFolders(account: UUID) -> [MailFolder]? {
        let url = dir(account).appendingPathComponent("folders.json")
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([MailFolder].self, from: d)
    }

    static func saveRaw(_ data: Data, account: UUID, folder: String, uid: Int) {
        try? data.write(to: dir(account).appendingPathComponent(fileName(["raw", folder, String(uid)])))
    }

    static func hasRaw(account: UUID, folder: String, uid: Int) -> Bool {
        FileManager.default.fileExists(atPath: dir(account).appendingPathComponent(fileName(["raw", folder, String(uid)])).path)
    }

    static func loadRaw(account: UUID, folder: String, uid: Int) -> Data? {
        let name = fileName(["raw", folder, String(uid)])
        let url = dir(account).appendingPathComponent(name)
        if let d = try? Data(contentsOf: url) {
            // 记下最近一次打开的时间，自动转存只挑很久没看的邮件
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return d
        }
        // 已转存到 iCloud / “文件”的存档里
        return CacheArchive.load(account: account, name: name)
    }

    static func removeAccount(_ account: UUID) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(account.uuidString))
    }

    static func clear() {
        try? FileManager.default.removeItem(at: root)
    }

    static var sizeDescription: String {
        let fm = FileManager.default
        var total = 0
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in e {
                total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return Fmt.size(total)
    }
}
