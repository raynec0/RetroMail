import SwiftUI

// MARK: - 图标库（Oxygen / Tango，见 README 致谢）

enum MailboxIconLibrary {
    struct IconGroup: Identifiable {
        let title: String
        let names: [String]
        var id: String { title }
    }

    static var groups: [IconGroup] {
        [
            IconGroup(title: tr("邮件", "Mail"), names: [
                "mbx-inbox", "mbx-sent", "mbx-drafts", "mbx-mail", "mbx-archive", "mbx-junk", "mbx-trash", "mbx-attach",
            ]),
            IconGroup(title: tr("彩色文件夹", "Colored Folders"), names: [
                "mbx-folder-blue", "mbx-folder-cyan", "mbx-folder-green", "mbx-folder-yellow", "mbx-folder-orange",
                "mbx-folder-red", "mbx-folder-violet", "mbx-folder-brown", "mbx-folder-grey", "mbx-folder-black",
            ]),
            IconGroup(title: tr("带标志的文件夹", "Folders with Badges"), names: [
                "mbx-folder-important", "mbx-folder-star", "mbx-folder-locked", "mbx-folder-bookmark", "mbx-folder-docs",
                "mbx-folder-text", "mbx-folder-image", "mbx-folder-download", "mbx-folder-box", "mbx-folder-temp",
                "mbx-folder-public", "mbx-folder-web", "mbx-folder-network", "mbx-folder-cloud", "mbx-folder-dev",
            ]),
            IconGroup(title: tr("工作与生活", "Work & Life"), names: [
                "mbx-important", "mbx-favorite", "mbx-calendar", "mbx-contacts", "mbx-people", "mbx-chat",
                "mbx-document", "mbx-sheet", "mbx-office", "mbx-engineering", "mbx-server", "mbx-globe",
                "mbx-news", "mbx-home", "mbx-info", "mbx-sun",
            ]),
        ]
    }
}

extension MailFolder {
    /// 首页显示的图标：用户选的优先，否则按文件夹类型自动选。
    func icon(for account: UUID) -> String {
        AppSettings.shared.folderIcon(account: account, path: path) ?? assetIcon
    }

    var isSystem: Bool { role != .other }
}

// MARK: - 新建 / 编辑邮箱

struct FolderEditView: View {
    let account: MailAccount
    let folder: MailFolder?

    @ObservedObject private var center = MailCenter.shared
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var parentPath: String?
    @State private var icon: String?
    @State private var busy = false
    @State private var message: String?
    @State private var confirmDelete = false

    init(account: MailAccount, folder: MailFolder?, parent: MailFolder? = nil) {
        self.account = account
        self.folder = folder
        _name = State(initialValue: folder?.lastName ?? "")
        if let f = folder, f.depth > 0, let d = f.delimiter {
            let comps = f.path.components(separatedBy: d)
            _parentPath = State(initialValue: comps.dropLast().joined(separator: d))
        } else {
            _parentPath = State(initialValue: parent?.path)
        }
        _icon = State(initialValue: folder.flatMap { AppSettings.shared.folderIcon(account: account.id, path: $0.path) })
    }

    private var isNew: Bool { folder == nil }
    private var canRename: Bool { folder.map { !$0.isSystem } ?? true }
    private var allFolders: [MailFolder] { center.folders[account.id] ?? [] }

    /// 可以作为上级的文件夹：排除自己和自己的子文件夹。
    private var parentChoices: [MailFolder] {
        allFolders.filter { f in
            guard let me = folder else { return true }
            if f.path == me.path { return false }
            if let d = me.delimiter, f.path.hasPrefix(me.path + d) { return false }
            return true
        }
    }

    private var parentName: String {
        guard let p = parentPath, let f = allFolders.first(where: { $0.path == p }) else { return tr("顶层", "Top Level") }
        return f.components.joined(separator: " › ")
    }

    private var previewFolder: MailFolder {
        let base = folder ?? MailFolder(path: name.isEmpty ? tr("新邮箱", "New Mailbox") : name, delimiter: nil, flags: [])
        return base
    }

    private var effectiveIcon: String { icon ?? previewFolder.assetIcon }

    var body: some View {
        RetroScreen(title: isNew ? tr("新建邮箱", "New Mailbox") : tr("编辑邮箱", "Edit Mailbox"),
                    back: tr("邮箱", "Mailboxes")) {
            Button(tr("存储", "Save")) { save() }
                .buttonStyle(BarButtonStyle(kind: .done))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    preview
                    RetroGroup(tr("名称", "Name")) {
                        HStack {
                            TextField(tr("邮箱名称", "Mailbox name"), text: $name)
                                .font(RT.font(17, .bold))
                                .foregroundColor(IOS3.value)
                                .disabled(!canRename)
                                .textInputAutocapitalization(.never)
                            if !canRename {
                                Text(tr("系统邮箱不能改名", "System mailbox")).font(RT.font(12)).foregroundColor(IOS3.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                    }
                    if canRename {
                        RetroGroup(tr("位置", "Location")) {
                            Menu {
                                Button(tr("顶层", "Top Level")) { parentPath = nil }
                                ForEach(parentChoices) { f in
                                    Button(String(repeating: "    ", count: f.depth) + f.lastName) { parentPath = f.path }
                                }
                            } label: {
                                HStack {
                                    Text(tr("位于", "Inside")).font(RT.font(15, .bold)).foregroundColor(.ink)
                                    Spacer()
                                    Text(parentName).font(RT.font(15)).foregroundColor(IOS3.value).lineLimit(1)
                                    Chevron()
                                }
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                        }
                    }
                    iconPicker
                    if let f = folder, !f.isSystem {
                        Button(tr("删除邮箱", "Delete Mailbox")) { confirmDelete = true }
                            .buttonStyle(RetroButtonStyle(destructive: true))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 18)
                    }
                    Text(tr("新建、改名和删除会直接在邮件服务器上进行，其他设备上也会同步看到。图标只保存在本机。",
                            "Creating, renaming and deleting happen on the mail server, so other devices see the change. Icons are stored on this device only."))
                        .font(RT.font(12))
                        .foregroundColor(IOS3.groupHeader)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 30)
            }
        }
        .busyOverlay(busy, tr("正在与服务器同步…", "Talking to the server…"))
        .retroAlert($message)
        .ios3ActionSheet(isPresented: $confirmDelete,
                         title: tr("删除“\(folder?.lastName ?? "")”后，里面的邮件也会从服务器上删除，无法恢复。",
                                   "Deleting “\(folder?.lastName ?? "")” also deletes the messages in it from the server. This can't be undone."),
                         actions: [SheetAction(tr("删除邮箱", "Delete Mailbox"), role: .destructive) { delete() }])
    }

    private var preview: some View {
        MailboxBarLabel(folder: previewFolder, icon: effectiveIcon, count: 0, showIcon: true, displayName: name.isEmpty ? nil : (folder?.isSystem == true ? nil : name))
            .modifier(StaticBarStyle())
            .padding(.top, 14)
            .allowsHitTesting(false)
    }

    private var iconPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tr("图标", "Icon"))
                    .font(RT.font(16, .bold))
                    .foregroundColor(IOS3.groupHeader)
                    .shadow(color: IOS3.groupHeaderShadow, radius: 0, x: 0, y: 1)
                Spacer()
                Button(tr("自动", "Automatic")) { icon = nil }
                    .buttonStyle(RetroButtonStyle(isDefault: icon == nil, compact: true))
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(MailboxIconLibrary.groups) { g in
                    Text(g.title).font(RT.font(12, .bold)).foregroundColor(IOS3.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52, maximum: 64), spacing: 6)], spacing: 6) {
                        ForEach(g.names, id: \.self) { n in
                            Button { icon = n } label: {
                                Image(n)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 40, height: 40)
                                    .padding(6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(effectiveIcon == n ? IOS3.dateBlue.opacity(0.18) : Color.clear)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .stroke(effectiveIcon == n ? IOS3.dateBlue : Color.clear, lineWidth: 2)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(IOS3.cell))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(IOS3.groupBorder, lineWidth: 1))
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let d = allFolders.compactMap(\.delimiter).first, !d.isEmpty, trimmed.contains(d) {
            message = tr("名称里不能包含“\(d)”。", "The name can't contain “\(d)”.")
            return
        }
        let parent = parentPath.flatMap { p in allFolders.first { $0.path == p } }
        let newPath = center.path(for: trimmed, parent: parent, account: account)
        busy = true
        Task {
            defer { busy = false }
            do {
                if let f = folder {
                    var finalPath = f.path
                    if canRename, newPath != f.path {
                        if allFolders.contains(where: { $0.path == newPath }) {
                            message = tr("已经有同名的邮箱了。", "A mailbox with that name already exists.")
                            return
                        }
                        try await center.renameFolder(account, from: f.path, to: newPath)
                        finalPath = newPath
                    }
                    settings.setFolderIcon(icon, account: account.id, path: finalPath)
                } else {
                    if allFolders.contains(where: { $0.path == newPath }) {
                        message = tr("已经有同名的邮箱了。", "A mailbox with that name already exists.")
                        return
                    }
                    try await center.createFolder(account, path: newPath)
                    settings.setFolderIcon(icon, account: account.id, path: newPath)
                }
                dismiss()
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func delete() {
        guard let f = folder else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await center.deleteFolder(account, path: f.path)
                dismiss()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

/// 预览用：和首页长条按钮一样的外观，但不可点按。
struct StaticBarStyle: ViewModifier {
    func body(content: Content) -> some View {
        Button {} label: { content }
            .buttonStyle(MailboxBarStyle())
    }
}
