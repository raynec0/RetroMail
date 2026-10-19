import SwiftUI

/// 设置 → 存储：本机缓存大小、转存到 iCloud 云盘、自动转存。
struct CacheSettingsView: View {
    @State private var localSize = "…"
    @State private var mailSize = "…"
    @State private var archive: String = "…"
    @State private var folderName = CacheArchive.folderDisplayName
    @State private var configured = CacheArchive.isConfigured
    @State private var autoDays = CacheArchive.autoDays
    @State private var busy = false
    @State private var message: String?
    @State private var confirmClearLocal = false
    @State private var confirmClearArchive = false
    @State private var offloadAge = 0
    @State private var deleteAfterExport = true

    var body: some View {
        RetroScreen(title: tr("存储", "Storage"), back: tr("设置", "Settings")) {
            EmptyView()
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    RetroGroup(tr("本机", "On This iPhone")) {
                        line(tr("离线缓存合计", "Offline cache total"), localSize)
                        line(tr("其中邮件原文和附件", "Of which messages & attachments"), mailSize)
                        Button(tr("清除本机缓存…", "Clear Local Cache…")) { confirmClearLocal = true }
                            .buttonStyle(RetroButtonStyle(compact: true))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }

                    RetroGroup(tr("iCloud 存档", "iCloud Archive")) {
                        HStack(spacing: 10) {
                            Image("mbx-folder-cloud").resizable().interpolation(.high).frame(width: 34, height: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tr("存档文件夹", "Archive folder")).font(RT.font(15, .bold))
                                Text(folderName).font(RT.font(13)).foregroundColor(IOS3.value).lineLimit(1)
                            }
                            Spacer()
                            Button(configured ? tr("更改…", "Change…") : tr("选择…", "Choose…")) { pickFolder() }
                                .buttonStyle(RetroButtonStyle(isDefault: !configured, compact: true))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        if configured {
                            line(tr("已存档", "Archived"), archive)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(tr("转存哪些邮件", "Move which messages")).font(RT.font(15, .bold))
                                IOS3Segmented(options: [(0, tr("全部", "All")), (7, tr("7 天前", "> 7 days")),
                                                        (30, tr("30 天前", "> 30 days")), (90, tr("90 天前", "> 90 days"))],
                                              selection: $offloadAge)
                                Button(tr("立即转存到 iCloud", "Move to iCloud Now")) { offload() }
                                    .buttonStyle(RetroButtonStyle(isDefault: true))
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(12)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(tr("自动转存很久没打开的邮件", "Automatically move mail not opened for"))
                                    .font(RT.font(15, .bold))
                                IOS3Segmented(options: [(0, tr("关闭", "Off")), (14, tr("14 天", "14 days")),
                                                        (30, tr("30 天", "30 days")), (90, tr("90 天", "90 days"))],
                                              selection: $autoDays)
                            }
                            .padding(12)
                            HStack(spacing: 10) {
                                Button(tr("清空存档…", "Empty Archive…")) { confirmClearArchive = true }
                                    .buttonStyle(RetroButtonStyle(compact: true, destructive: true))
                                Button(tr("不再使用存档", "Stop Using Archive")) {
                                    CacheArchive.forget()
                                    reload()
                                }
                                .buttonStyle(RetroButtonStyle(compact: true))
                            }
                            .padding(12)
                        }
                    }

                    RetroGroup(tr("导出到 iCloud 云盘（压缩包）", "Export to iCloud Drive (zip)")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tr("不想设置存档文件夹的话，也可以把缓存的邮件打成一个压缩包，存到 iCloud 云盘或任何位置（每封邮件是一个 .eml 文件，电脑上的邮件程序也能打开）。",
                                    "Or pack the cached messages into one .zip and save it to iCloud Drive or anywhere (each message is an .eml file your computer's mail app can open)."))
                                .font(RT.font(12))
                                .fixedSize(horizontal: false, vertical: true)
                            IOS3Segmented(options: [(0, tr("全部", "All")), (7, tr("7 天前", "> 7 days")),
                                                    (30, tr("30 天前", "> 30 days")), (90, tr("90 天前", "> 90 days"))],
                                          selection: $offloadAge)
                            RetroCheckbox(label: tr("存好后删除本机副本（以后打开会从服务器重新下载）", "Delete local copies after saving (re-downloaded from the server when opened)"), isOn: $deleteAfterExport)
                            Button(tr("导出压缩包…", "Export Zip…")) { exportZip() }
                                .buttonStyle(RetroButtonStyle(isDefault: !configured))
                                .frame(maxWidth: .infinity)
                        }
                        .padding(12)
                    }

                    Text(tr("""
                    选择存档文件夹：在弹出的“文件”里进入 iCloud 云盘，打开（或新建后打开）你想用的文件夹，再点右上角“打开”。
                    转存后本机只留邮件列表，邮件原文和附件放到你选的文件夹（建议选 iCloud 云盘里的一个文件夹）。打开转存过的邮件时会从那里读取；如果 iCloud 还没下载到手机上，会改为从邮件服务器重新下载，所以不会丢邮件。
                    邮件仍然保存在邮件服务器上，转存只是为了腾出手机空间。自签安装的应用无法直接使用 iCloud 容器，所以用“文件”里的文件夹来实现。
                    """, """
                    After moving, only the message lists stay on the phone; message files and attachments go to the folder you pick (an iCloud Drive folder is best). Archived messages are read from there; if iCloud hasn't downloaded a file yet, the message is fetched again from your mail server, so nothing is lost.
                    Your mail stays on the mail server — this only frees space on the phone. Self-signed apps can't use an iCloud container directly, so a Files folder is used instead.
                    """))
                        .font(RT.font(12))
                        .foregroundColor(IOS3.groupHeader)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                }
                .padding(14)
            }
        }
        .busyOverlay(busy, tr("正在转存…", "Moving…"))
        .retroAlert($message)
        .ios3ActionSheet(isPresented: $confirmClearLocal,
                         title: tr("会删除本机上的全部离线缓存（列表和邮件）。存档和服务器上的邮件不受影响。",
                                   "Deletes all offline data on this phone. The archive and your server mail are not affected."),
                         actions: [SheetAction(tr("清除本机缓存", "Clear Local Cache"), role: .destructive) {
                             Task {
                                 await Task.detached { DiskCache.clear() }.value
                                 reload()
                             }
                         }])
        .ios3ActionSheet(isPresented: $confirmClearArchive,
                         title: tr("会删除存档文件夹里的全部邮件文件。服务器上的邮件不受影响。",
                                   "Deletes all files in the archive folder. Mail on your server is not affected."),
                         actions: [SheetAction(tr("清空存档", "Empty Archive"), role: .destructive) {
                             do { try CacheArchive.clearArchive() } catch { message = error.localizedDescription }
                             reload()
                         }])
        .onChange(of: autoDays) { CacheArchive.autoDays = $0 }
        .onAppear { reload() }
    }

    private func line(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(RT.font(15, .bold))
            Spacer()
            Text(value).font(RT.font(15)).foregroundColor(IOS3.value)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }

    private func reload() {
        configured = CacheArchive.isConfigured
        folderName = CacheArchive.folderDisplayName
        Task {
            let (total, mail, arch) = await Task.detached { () -> (String, String, String) in
                let st = CacheArchive.stats()
                let a = st.map { tr("\($0.files) 封 · ", "\($0.files) msgs · ") + Fmt.size($0.bytes) } ?? "—"
                return (DiskCache.sizeDescription, Fmt.size(DiskCache.rawSize), a)
            }.value
            localSize = total
            mailSize = mail
            archive = arch
        }
    }

    private func pickFolder() {
        FilesPresenter.pickFolder { url in
            do {
                try CacheArchive.setFolder(url)
                reload()
                message = tr("✓ 已设置存档文件夹：", "✓ Archive folder set: ") + CacheArchive.folderDisplayName
            } catch {
                message = error.localizedDescription
                reload()
            }
        }
    }

    private func exportZip() {
        busy = true
        let age = offloadAge
        let remove = deleteAfterExport
        Task {
            let r = await Task.detached { () -> Result<(zip: URL, files: [DiskCache.RawFile], bytes: Int), Error> in
                do { return .success(try CacheArchive.makeZip(olderThanDays: age)) } catch { return .failure(error) }
            }.value
            busy = false
            switch r {
            case .failure(let e):
                message = e.localizedDescription
            case .success(let pack):
                FilesPresenter.export(pack.zip) { saved in
                    try? FileManager.default.removeItem(at: pack.zip.deletingLastPathComponent())
                    guard saved else { return }
                    if remove { CacheArchive.removeLocal(pack.files) }
                    message = remove
                        ? tr("已保存 \(pack.files.count) 封邮件，并腾出 \(Fmt.size(pack.bytes))。", "Saved \(pack.files.count) messages and freed \(Fmt.size(pack.bytes)).")
                        : tr("已保存 \(pack.files.count) 封邮件。", "Saved \(pack.files.count) messages.")
                    reload()
                }
            }
        }
    }

    private func offload() {
        busy = true
        let age = offloadAge
        Task {
            defer { busy = false }
            let r = await Task.detached { () -> Result<CacheArchive.Result, Error> in
                do { return .success(try CacheArchive.offload(olderThanDays: age)) } catch { return .failure(error) }
            }.value
            switch r {
            case .success(let res):
                message = res.files == 0
                    ? tr("没有需要转存的邮件。", "Nothing to move.")
                    : tr("已转存 \(res.files) 封邮件，腾出 \(Fmt.size(res.bytes))。", "Moved \(res.files) messages, freed \(Fmt.size(res.bytes)).")
            case .failure(let e):
                message = e.localizedDescription
            }
            reload()
        }
    }
}
