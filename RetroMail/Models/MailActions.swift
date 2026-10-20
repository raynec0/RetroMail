import Foundation
import SwiftUI

/// 本地优先的操作队列（参考 Apple 邮件 / Spark 的做法）：
/// 移动、归档、删除、标记已读、旗标先在本机立即生效，界面不等服务器；
/// 操作写进队列（存到磁盘，闪退或断网也不会丢），由专用连接按顺序发给服务器，失败自动重试。
/// 刷新列表时，还没同步完的操作会盖在服务器结果上，邮件不会“跳回来”。
struct PendingAction: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case move, delete, flag }

    var id = UUID()
    var account: UUID
    var folder: String
    var uids: [Int]
    var kind: Kind
    /// move：目标文件夹；delete：废纸篓（nil 表示直接彻底删除）
    var dest: String?
    var flag: String?
    var on = true
    /// 移动时的邮件快照，用来立即插到目标文件夹里
    var messages: [MessageSummary] = []
    var attempts = 0
    var created = Date()

    static func == (a: PendingAction, b: PendingAction) -> Bool { a.id == b.id }
}

@MainActor
final class MailActions: ObservableObject {
    static let shared = MailActions()

    @Published private(set) var pending: [PendingAction] = []
    /// 已执行的移动：动作 ID → 新 UID（撤销用）
    private var completedMoves: [UUID: (account: UUID, from: String, to: String, map: [Int: Int])] = [:]
    private var workers: Set<UUID> = []

    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("pending-actions.json")
    }

    private init() {
        if let d = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([PendingAction].self, from: d) {
            pending = list
        }
    }

    private func persist() {
        let list = pending
        let target = url
        DiskCache.io.async {
            if let d = try? JSONEncoder().encode(list) { try? d.write(to: target, options: .atomic) }
        }
    }

    // MARK: 叠加到服务器结果上

    /// 还没同步到服务器的操作：要隐藏的邮件（已移走 / 删除）
    func hiddenUIDs(account: UUID, folder: String) -> Set<Int> {
        var s = Set<Int>()
        for a in pending where a.account == account && a.folder == folder && a.kind != .flag {
            s.formUnion(a.uids)
        }
        return s
    }

    /// 把还没同步的操作盖到一份邮件列表上。
    func overlay(_ list: [MessageSummary], account: UUID, folder: String) -> [MessageSummary] {
        let mine = pending.filter { $0.account == account && $0.folder == folder }
        guard !mine.isEmpty else { return list }
        let hidden = hiddenUIDs(account: account, folder: folder)
        var out = list.filter { !hidden.contains($0.uid) }
        for a in mine where a.kind == .flag {
            guard let f = a.flag else { continue }
            let set = Set(a.uids)
            for i in out.indices where set.contains(out[i].uid) { out[i].set(f, a.on) }
        }
        return out
    }

    // MARK: 加入队列

    /// 临时条目（还没同步的移动，UID 记为负数）真正在哪个文件夹、哪个 UID。
    func resolve(account: UUID, folder: String, uid: Int) -> (folder: String, uid: Int)? {
        guard uid < 0 else { return nil }
        let old = -uid
        if let a = pending.first(where: { $0.account == account && $0.dest == folder && $0.uids.contains(old) }) {
            return (a.folder, old)
        }
        for (_, m) in completedMoves where m.account == account && m.to == folder {
            if let n = m.map[old] { return (folder, n) }
        }
        return nil
    }

    @discardableResult
    func enqueue(_ action: PendingAction) -> UUID {
        var a = action
        a.uids = a.uids.filter { $0 > 0 }
        a.messages = a.messages.filter { $0.uid > 0 }
        guard !a.uids.isEmpty else { return a.id }
        // 同一封邮件的同一个旗标只保留最后一次
        if a.kind == .flag {
            pending.removeAll { $0.kind == .flag && $0.account == a.account && $0.folder == a.folder && $0.flag == a.flag && Set($0.uids) == Set(a.uids) && !running.contains($0.id) }
        }
        pending.append(a)
        persist()
        kick(a.account)
        return a.id
    }

    /// 撤销：还在排队就直接取消；已经执行过的移动就移回去。返回 true 表示已撤销。
    func undo(_ id: UUID) -> Bool {
        if let i = pending.firstIndex(where: { $0.id == id }), !running.contains(id) {
            let a = pending.remove(at: i)
            persist()
            restoreLocally(a)
            return true
        }
        if let done = completedMoves.removeValue(forKey: id), !done.map.isEmpty,
           let acc = AccountStore.shared.accounts.first(where: { $0.id == done.account }) {
            let back = PendingAction(account: done.account, folder: done.to, uids: Array(done.map.values), kind: .move, dest: done.from)
            if let live = MessageListModel.liveModel(account: acc.id, folder: done.to) {
                live.removeLocally(Set(done.map.values))
            }
            enqueue(back)
            return true
        }
        return false
    }

    private func restoreLocally(_ a: PendingAction) {
        guard !a.messages.isEmpty, let live = MessageListModel.liveModel(account: a.account, folder: a.folder) else {
            if let live = MessageListModel.liveModel(account: a.account, folder: a.folder) { Task { await live.refresh() } }
            return
        }
        live.insertMoved(a.messages)
        if let d = a.dest, let target = MessageListModel.liveModel(account: a.account, folder: d) {
            target.removeLocally(Set(a.uids.map { -$0 }))
        }
    }

    // MARK: 执行

    private var running: Set<UUID> = []

    /// 网络恢复、回到前台时调用：把积压的操作发出去。
    func kickAll() {
        for id in Set(pending.map(\.account)) { kick(id) }
    }

    private func kick(_ account: UUID) {
        guard !workers.contains(account) else { return }
        workers.insert(account)
        Task { [weak self] in
            await self?.drain(account)
            self?.workers.remove(account)
        }
    }

    private func drain(_ accountId: UUID) async {
        while let next = pending.first(where: { $0.account == accountId }) {
            guard let acc = AccountStore.shared.accounts.first(where: { $0.id == accountId }) else {
                pending.removeAll { $0.account == accountId }
                persist()
                return
            }
            running.insert(next.id)
            let result = await execute(next, account: acc)
            running.remove(next.id)
            switch result {
            case .done:
                pending.removeAll { $0.id == next.id }
                persist()
            case .retry:
                guard let i = pending.firstIndex(where: { $0.id == next.id }) else { continue }
                pending[i].attempts += 1
                persist()
                if pending[i].attempts >= 8 {
                    let failed = pending.remove(at: i)
                    persist()
                    fail(failed, account: acc, message: tr("网络一直连不上，这个操作没能同步到服务器，已恢复原样。", "Couldn't reach the server, so the change was undone."))
                    continue
                }
                // 断网时不要空转：退避等待，网络恢复时会被重新唤起
                let wait = [2, 5, 10, 20, 40, 60, 90, 120][min(pending[i].attempts - 1, 7)]
                try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            case .failed(let msg):
                pending.removeAll { $0.id == next.id }
                persist()
                fail(next, account: acc, message: msg)
            }
        }
    }

    private enum Outcome { case done, retry, failed(String) }

    private func execute(_ a: PendingAction, account acc: MailAccount) async -> Outcome {
        let c = MailCenter.shared.client(for: acc, .actions)
        do {
            switch a.kind {
            case .flag:
                guard let f = a.flag else { return .done }
                try await c.perform(timeout: 45) { try await $0.store(a.folder, uids: a.uids, flag: f, add: a.on) }
                if f.caseInsensitiveCompare("\\Seen") == .orderedSame {
                    MailCenter.shared.updateBadge()
                }
            case .move:
                guard let d = a.dest else { return .done }
                let map = try await c.perform(timeout: 90) { try await $0.move(a.folder, uids: a.uids, to: d) }
                completedMoves[a.id] = (acc.id, a.folder, d, map)
                finishMove(a, account: acc, dest: d, map: map)
            case .delete:
                let map = try await c.perform(timeout: 90) { try await $0.delete(a.folder, uids: a.uids, trash: a.dest) }
                if let d = a.dest { finishMove(a, account: acc, dest: d, map: map) }
            }
            return .done
        } catch let e as MailError {
            if e.isConnectionError { return .retry }
            // 服务器明确拒绝（邮件已不存在等）：放弃并以服务器为准
            return .failed(e.localizedDescription)
        } catch {
            return .retry
        }
    }

    private func finishMove(_ a: PendingAction, account acc: MailAccount, dest: String, map: [Int: Int]) {
        let center = MailCenter.shared
        let destFolder = center.folders[acc.id]?.first { $0.path == dest } ?? MailFolder(path: dest, delimiter: nil, flags: [])
        // 目标文件夹：把临时条目换成服务器分配的真正 UID
        if let live = MessageListModel.liveModel(account: acc.id, folder: dest) {
            live.removeLocally(Set(a.uids.map { -$0 }))
        }
        center.didMove(acc, from: a.folder, to: destFolder, messages: a.messages, uidMap: map, announce: false)
        // 下载过的正文跟着改名，打开时不用重新下载
        let accountId = acc.id
        let src = a.folder
        Task.detached(priority: .utility) {
            for (old, new) in map {
                if let raw = DiskCache.loadRaw(account: accountId, folder: src, uid: old) {
                    DiskCache.saveRaw(raw, account: accountId, folder: dest, uid: new)
                }
            }
        }
        Task { await center.refreshUnread(acc, paths: [a.folder, dest]) }
    }

    private func fail(_ a: PendingAction, account acc: MailAccount, message: String) {
        MailCenter.shared.showToast(MailToast(text: message, undo: nil))
        for path in [a.folder, a.dest].compactMap({ $0 }) {
            if let live = MessageListModel.liveModel(account: acc.id, folder: path) {
                Task { await live.refresh() }
            }
        }
        Task { await MailCenter.shared.refreshUnread(acc) }
    }
}
