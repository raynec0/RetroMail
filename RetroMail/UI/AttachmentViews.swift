import SwiftUI
import UIKit
import EventKit
import EventKitUI

struct FileItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

// MARK: - 系统分享 / 存储到“文件”

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ExportPicker: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
}

// MARK: - 附件列表（点按打开；“⋯”更多操作；多个附件可全部存储）

struct AttachmentList: View {
    let attachments: [MailAttachment]
    let account: MailAccount

    @EnvironmentObject private var settings: AppSettings
    @State private var preview: PreviewItem?
    @State private var embedded: MailAttachment?
    @State private var invite: MailAttachment?
    @State private var share: FileItem?
    @State private var export: FileItem?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 8) {
            if attachments.count > 1 {
                HStack {
                    Text(tr("\(attachments.count) 个附件 · \(Fmt.size(attachments.reduce(0) { $0 + $1.data.count }))",
                            "\(attachments.count) attachments · \(Fmt.size(attachments.reduce(0) { $0 + $1.data.count }))"))
                        .font(RT.font(13))
                        .foregroundColor(IOS3.secondary)
                    Spacer()
                    Button(tr("全部存储", "Save All")) { exportAll() }
                        .font(RT.font(13, .bold))
                        .foregroundColor(IOS3.dateBlue)
                        .buttonStyle(.plain)
                }
            }
            ForEach(attachments) { att in
                row(att)
            }
        }
        .sheet(item: $preview) { item in
            QuickLookView(url: item.url).ignoresSafeArea()
        }
        .sheet(item: $embedded) { att in
            EmbeddedMessageView(attachment: att, account: account)
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
        }
        .sheet(item: $invite) { att in
            CalendarInviteView(data: att.data, account: account)
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
        }
        .sheet(item: $share) { item in
            ShareSheet(urls: item.urls).ignoresSafeArea()
        }
        .sheet(item: $export) { item in
            ExportPicker(urls: item.urls).ignoresSafeArea()
        }
        .retroAlert($error)
    }

    private func row(_ att: MailAttachment) -> some View {
        HStack(spacing: 0) {
            Button {
                open(att)
            } label: {
                AttachmentRowLabel(attachment: att)
            }
            .buttonStyle(InvertOnPressStyle())
            Rectangle().fill(IOS3.groupBorder).frame(width: 1)
            Button {
                more(att)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(IOS3.value)
                    .frame(width: 46)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(InvertOnPressStyle())
        }
        .frame(minHeight: 50)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(IOS3.groupBorder, lineWidth: 1))
    }

    private func open(_ att: MailAttachment) {
        switch AttachmentKind.of(att) {
        case .email: embedded = att
        case .calendar: invite = att
        default:
            do {
                preview = PreviewItem(url: try AttachmentFiles.write(att))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func more(_ att: MailAttachment) {
        var actions: [SheetAction] = []
        switch AttachmentKind.of(att) {
        case .email:
            actions.append(SheetAction(tr("查看邮件", "View Message")) { embedded = att })
        case .calendar:
            actions.append(SheetAction(tr("查看邀请", "View Invitation")) { invite = att })
        default:
            actions.append(SheetAction(tr("预览", "Quick Look")) { open(att) })
        }
        actions.append(SheetAction(tr("存储到“文件”", "Save to Files")) { withFile(att) { export = FileItem(urls: [$0]) } })
        actions.append(SheetAction(tr("共享 / 用其他 App 打开", "Share / Open In…")) { withFile(att) { share = FileItem(urls: [$0]) } })
        SheetCenter.shared.present(att.filename, actions)
    }

    private func withFile(_ att: MailAttachment, _ then: (URL) -> Void) {
        do {
            then(try AttachmentFiles.write(att))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func exportAll() {
        do {
            export = FileItem(urls: try attachments.map { try AttachmentFiles.write($0) })
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AttachmentRowLabel: View {
    let attachment: MailAttachment
    @Environment(\.rowPressed) private var pressed

    private var icon: String {
        switch AttachmentKind.of(attachment) {
        case .email: return "envelope"
        case .calendar: return "calendar"
        default: return AttachmentFiles.icon(for: attachment.mimeType)
        }
    }

    private var subtitle: String {
        switch AttachmentKind.of(attachment) {
        case .email: return tr("邮件", "Email message") + " · " + Fmt.size(attachment.data.count)
        case .calendar: return tr("会议邀请", "Calendar invitation") + " · " + Fmt.size(attachment.data.count)
        default:
            let ext = (attachment.filename as NSString).pathExtension.uppercased()
            return (ext.isEmpty ? "" : ext + " · ") + Fmt.size(attachment.data.count)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(pressed ? .white : IOS3.value)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename).font(RT.font(14, .bold)).lineLimit(2)
                Text(subtitle).font(RT.font(12)).foregroundColor(pressed ? .white : IOS3.secondary)
            }
            Spacer(minLength: 4)
            Chevron()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - 附件里的邮件（.eml）

struct EmbeddedMessageView: View {
    let attachment: MailAttachment
    let account: MailAccount

    @EnvironmentObject private var settings: AppSettings
    @State private var display: MessageDisplay?
    @State private var height: CGFloat = 1
    @State private var allowRemote = false
    @State private var compose: ComposeRequest?
    @State private var details = false

    var body: some View {
        RetroPanel(display?.parsed.subject.isEmpty == false ? display!.parsed.subject : attachment.filename) {
            if let d = display {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            header(d.parsed)
                            RetroDivider()
                            if d.hasRemote && !allowRemote {
                                Button(tr("载入全部图片", "Load All Images")) { allowRemote = true }
                                    .font(RT.font(14, .bold))
                                    .foregroundColor(IOS3.dateBlue)
                                    .buttonStyle(.plain)
                                    .padding(12)
                            }
                            AutoHeightHTMLView(html: d.page(remote: allowRemote, hideQuotes: false), hideQuotes: false,
                                               height: $height, onQuoteDetected: nil,
                                               onMailto: { compose = ComposeRequest(account: account, to: $0) })
                                .frame(height: max(height, 60))
                                .id(allowRemote ? "r" : "n")
                            if !d.parsed.attachments.isEmpty {
                                AttachmentList(attachments: d.parsed.attachments, account: account)
                                    .padding(12)
                            }
                        }
                    }
                    .background(IOS3.cell)
                    IOS3Toolbar {
                        ToolbarIcon(symbol: "arrowshape.turn.up.left", label: tr("回复", "Reply")) { start(.reply, d) }
                        ToolbarIcon(symbol: "arrowshape.turn.up.left.2", label: tr("全部回复", "Reply All")) { start(.replyAll, d) }
                        ToolbarIcon(symbol: "arrowshape.turn.up.right", label: tr("转发", "Forward")) { start(.forward, d) }
                    }
                }
            } else {
                VStack {
                    Spacer()
                    RetroBusy(text: tr("正在打开…", "Opening…"))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(IOS3.cell)
            }
        }
        .presentationDetents([.large])
        .task {
            if display == nil { display = await MessageDisplay.make(attachment.data) }
        }
        .fullScreenCover(item: $compose) {
            ComposeView(request: $0)
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
        }
    }

    private func start(_ mode: ComposeRequest.Mode, _ d: MessageDisplay) {
        compose = ComposeRequest(mode: mode, account: account, original: d.parsed)
    }

    private func header(_ p: ParsedMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(tr("发件人：", "From:")).font(RT.font(14)).foregroundColor(IOS3.secondary)
                if let f = p.from.first { AddressBubble(address: f, full: details) }
                Spacer()
                Button(details ? tr("隐藏", "Hide") : tr("详细信息", "Details")) { details.toggle() }
                    .font(RT.font(14, .bold))
                    .foregroundColor(IOS3.dateBlue)
                    .buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 6) {
                Text(tr("收件人：", "To:")).font(RT.font(14)).foregroundColor(IOS3.secondary)
                FlowRow(spacing: 5) {
                    ForEach(Array((details ? p.to + p.cc : Array(p.to.prefix(3))).enumerated()), id: \.offset) { _, a in
                        AddressBubble(address: a, full: details)
                    }
                }
            }
            RetroDivider().padding(.vertical, 2)
            Text(p.subject.isEmpty ? tr("（无主题）", "(No Subject)") : p.subject)
                .font(RT.font(17, .bold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let d = p.date {
                Text(Fmt.long(d)).font(RT.font(13)).foregroundColor(IOS3.secondary)
            }
        }
        .padding(12)
    }
}

// MARK: - 会议邀请（.ics）

struct CalendarInviteView: View {
    let data: Data
    let account: MailAccount

    @State private var events: [CalendarEvent] = []
    @State private var parsed = false
    @State private var busy: String?
    @State private var message: String?
    @State private var editing: EditingEvent?
    @State private var replied: String?
    private var store: EKEventStore { Self.store }
    static let store = EKEventStore()

    var body: some View {
        RetroPanel(tr("会议邀请", "Invitation")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !parsed {
                        RetroBusy().padding(20)
                    } else if events.isEmpty {
                        Text(tr("无法读取这个日历文件。", "This calendar file couldn't be read."))
                            .font(RT.font(15))
                            .foregroundColor(IOS3.groupHeader)
                            .padding(20)
                    }
                    ForEach(events.indices, id: \.self) { i in
                        eventView(events[i])
                    }
                }
                .padding(10)
            }
        }
        .presentationDetents([.large])
        .busyOverlay(busy != nil, busy ?? "")
        .retroAlert($message)
        .task {
            if !parsed {
                let d = data
                events = await Task.detached { ICS.parse(d) }.value
                parsed = true
            }
        }
        .sheet(item: $editing) { item in
            EventEditView(event: item.event, store: store).ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func eventView(_ e: CalendarEvent) -> some View {
        let me = e.attendee(account.email)
        RetroGroup(e.isCancelled ? tr("已取消的会议", "Cancelled") : (e.method.uppercased() == "REPLY" ? tr("会议回复", "Reply") : tr("会议", "Meeting"))) {
            VStack(alignment: .leading, spacing: 4) {
                Text(e.summary.isEmpty ? tr("（无标题）", "(No Title)") : e.summary)
                    .font(RT.font(18, .bold))
                    .strikethrough(e.isCancelled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(e.timeText).font(RT.font(14)).foregroundColor(IOS3.value)
                if !e.recurrence.isEmpty {
                    Text(tr("重复会议", "Repeating event")).font(RT.font(12)).foregroundColor(IOS3.secondary)
                }
            }
            if !e.location.isEmpty {
                infoRow(tr("地点", "Location"), e.location)
            }
            if !e.organizerEmail.isEmpty {
                infoRow(tr("组织者", "Organizer"), e.organizerName.isEmpty ? e.organizerEmail : "\(e.organizerName) <\(e.organizerEmail)>")
            }
            if let m = me {
                infoRow(tr("我的状态", "My Status"), replied ?? m.statusLabel)
            }
        }
        if e.isRequest && !e.isCancelled && !e.organizerEmail.isEmpty && !account.isMine(e.organizerEmail) {
            HStack(spacing: 8) {
                replyButton(e, "ACCEPTED", tr("接受", "Accept"))
                replyButton(e, "TENTATIVE", tr("暂定", "Maybe"))
                replyButton(e, "DECLINED", tr("拒绝", "Decline"))
            }
            .padding(.top, 12)
        }
        if !e.isCancelled {
            Button {
                addToCalendar(e)
            } label: {
                Label(tr("添加到日历", "Add to Calendar"), systemImage: "calendar.badge.plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(RetroButtonStyle())
            .padding(.top, 10)
        }
        if !e.attendees.isEmpty {
            RetroGroup(tr("参加者（\(e.attendees.count)）", "Attendees (\(e.attendees.count))")) {
                ForEach(e.attendees, id: \.self) { a in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.display).font(RT.font(14, .bold)).lineLimit(1)
                            if !a.name.isEmpty {
                                Text(a.email).font(RT.font(12)).foregroundColor(IOS3.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(a.statusLabel).font(RT.font(12)).foregroundColor(statusColor(a.status))
                    }
                }
            }
        }
        if !e.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            RetroGroup(tr("说明", "Notes")) {
                Text(e.description.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(RT.font(14))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(RT.font(15, .bold)).frame(width: 80, alignment: .leading)
            Text(value).font(RT.font(15)).foregroundColor(IOS3.value).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusColor(_ s: String) -> Color {
        switch s.uppercased() {
        case "ACCEPTED": return HexColor.color("#2E9E1E")
        case "DECLINED": return HexColor.color("#C21E12")
        case "TENTATIVE": return HexColor.color("#D97B00")
        default: return IOS3.secondary
        }
    }

    private func replyButton(_ e: CalendarEvent, _ partstat: String, _ label: String) -> some View {
        Button {
            sendReply(e, partstat: partstat, label: label)
        } label: {
            Text(label).frame(maxWidth: .infinity)
        }
        .buttonStyle(RetroButtonStyle(isDefault: partstat == "ACCEPTED", destructive: partstat == "DECLINED"))
    }

    private func sendReply(_ e: CalendarEvent, partstat: String, label: String) {
        let me = account.address
        let ics = ICS.reply(to: e, me: me, partstat: partstat)
        let prefix: String
        switch partstat {
        case "ACCEPTED": prefix = tr("已接受：", "Accepted: ")
        case "TENTATIVE": prefix = tr("暂定：", "Tentative: ")
        default: prefix = tr("已拒绝：", "Declined: ")
        }
        let who = me.name.isEmpty ? me.email : me.name
        var mail = OutgoingMail(from: me,
                                to: [MailAddress(name: e.organizerName, email: e.organizerEmail)],
                                cc: [], bcc: [],
                                subject: prefix + e.summary,
                                body: "\(who) \(label)：\(e.summary)\n\(e.timeText)",
                                html: nil, attachments: [], inReplyTo: nil, references: nil)
        mail.calendarMethod = "REPLY"
        mail.calendarICS = ics
        busy = tr("正在发送回复…", "Sending response…")
        let acc = account
        Task {
            do {
                try await MailCenter.shared.send(mail, account: acc, answered: nil, removeDraft: nil)
                busy = nil
                replied = label
                message = tr("已向组织者发送“\(label)”回复。", "Your “\(label)” response was sent to the organizer.")
            } catch {
                busy = nil
                message = error.localizedDescription
            }
        }
    }

    private func addToCalendar(_ e: CalendarEvent) {
        if #available(iOS 17.0, *) {
            editing = EditingEvent(event: e)
        } else {
            store.requestAccess(to: .event) { granted, _ in
                DispatchQueue.main.async {
                    if granted {
                        editing = EditingEvent(event: e)
                    } else {
                        message = tr("没有日历权限。请到“设置 > RetroMail”中允许访问日历。", "Calendar access is off. Allow it in Settings > RetroMail.")
                    }
                }
            }
        }
    }
}

struct EditingEvent: Identifiable {
    let id = UUID()
    let event: CalendarEvent
}

/// 系统的“新建日程”编辑器，预先填好邀请内容。
struct EventEditView: UIViewControllerRepresentable {
    let event: CalendarEvent
    let store: EKEventStore
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let vc = EKEventEditViewController()
        vc.eventStore = store
        let ev = EKEvent(eventStore: store)
        ev.title = event.summary
        let start = event.start ?? Date()
        ev.startDate = start
        ev.endDate = event.end ?? start.addingTimeInterval(3600)
        ev.isAllDay = event.allDay
        if !event.location.isEmpty { ev.location = event.location }
        if !event.description.isEmpty { ev.notes = event.description }
        if let cal = store.defaultCalendarForNewEvents { ev.calendar = cal }
        vc.event = ev
        vc.editViewDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let parent: EventEditView

        init(_ parent: EventEditView) {
            self.parent = parent
        }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            parent.dismiss()
        }
    }
}

/// 邮件正文上方的会议邀请横条。
struct InviteBanner: View {
    let event: CalendarEvent
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                VStack(spacing: 0) {
                    Text(monthText).font(RT.font(10, .bold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 1)
                        .background(HexColor.color("#D23426"))
                    Text(dayText).font(RT.font(20, .bold)).foregroundColor(.black)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white)
                }
                .frame(width: 42, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(IOS3.groupBorder, lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.summary.isEmpty ? tr("会议邀请", "Invitation") : event.summary)
                        .font(RT.font(15, .bold)).lineLimit(2)
                        .strikethrough(event.isCancelled)
                    Text(event.timeText).font(RT.font(12)).foregroundColor(IOS3.secondary).lineLimit(1)
                    if !event.location.isEmpty {
                        Text(event.location).font(RT.font(12)).foregroundColor(IOS3.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(event.isCancelled ? tr("已取消", "Cancelled") : tr("回复", "Respond"))
                    .font(RT.font(13, .bold))
                    .foregroundColor(IOS3.dateBlue)
                Chevron()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(HexColor.color("#EEF3FA")))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(HexColor.color("#9DB3D3"), lineWidth: 1))
            .foregroundColor(.black)
        }
        .buttonStyle(.plain)
    }

    private var monthText: String {
        guard let s = event.start else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: tr("zh_CN", "en_US"))
        f.dateFormat = tr("M月", "MMM")
        return f.string(from: s).uppercased()
    }

    private var dayText: String {
        guard let s = event.start else { return "?" }
        return String(Calendar.current.component(.day, from: s))
    }
}
