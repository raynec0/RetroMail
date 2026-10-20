import SwiftUI

// MARK: - 编辑一封邮件的跟进信息

struct FollowUpEditor: View {
    let initial: FollowUp
    /// 旗标变化时由调用方同步到服务器（会话页会顺便更新列表）；为空时这里直接同步。
    var onFlagChange: ((Bool) -> Void)?

    @ObservedObject private var store = FollowUpStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var f: FollowUp
    @State private var hasReminder: Bool
    @State private var hasDeadline: Bool
    @State private var message: String?
    @State private var busy = false
    @State private var confirmRemove = false

    init(item: FollowUp, onFlagChange: ((Bool) -> Void)? = nil) {
        initial = item
        self.onFlagChange = onFlagChange
        _f = State(initialValue: item)
        _hasReminder = State(initialValue: item.reminder != nil)
        _hasDeadline = State(initialValue: item.deadline != nil)
    }

    private var exists: Bool { store.item(initial.id) != nil }

    var body: some View {
        VStack(spacing: 0) {
            IOS3NavBar(title: tr("跟进", "Follow Up")) {
                Button(tr("取消", "Cancel")) { dismiss() }
                    .buttonStyle(BarButtonStyle())
            } trailing: {
                Button(tr("完成", "Done")) { save() }
                    .buttonStyle(BarButtonStyle(kind: .done))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    header
                    flagGroup
                    reminderGroup
                    deadlineGroup
                    noteGroup
                    statusGroup
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 30)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .foregroundColor(.ink)
        .background(PinstripeBackground().ignoresSafeArea())
        .busyOverlay(busy, tr("正在写入“提醒事项”…", "Saving to Reminders…"))
        .retroAlert($message)
        .ios3ActionSheet(isPresented: $confirmRemove, actions: [
            SheetAction(tr("移除跟进", "Remove Follow-up"), role: .destructive) {
                store.remove(initial.id)
                if initial.flagged { syncFlag(false) }
                dismiss()
            },
        ])
        .sheetHost()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(f.flagged ? f.flagColor.asset : "mbx-mail")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.subject)
                    .font(RT.font(16, .bold))
                    .foregroundColor(IOS3.groupHeader)
                    .shadow(color: IOS3.groupHeaderShadow, radius: 0, x: 0, y: 1)
                    .lineLimit(3)
                Text(f.sender + " · " + Fmt.compact(f.summary.received))
                    .font(RT.font(12))
                    .foregroundColor(IOS3.groupHeader)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 14)
    }

    private func row<C: View>(_ title: String, @ViewBuilder trailing: () -> C) -> some View {
        HStack {
            Text(title).font(RT.font(15, .bold))
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
    }

    private var flagGroup: some View {
        RetroGroup(tr("旗标", "Flag")) {
            row(tr("加旗标", "Flagged")) { IOS3Switch(isOn: $f.flagged) }
            if f.flagged {
                HStack(spacing: 14) {
                    Text(tr("颜色", "Color")).font(RT.font(15, .bold))
                    Spacer()
                    ForEach(FollowUp.FlagColor.allCases) { c in
                        Button { f.flagColor = c } label: {
                            Image(c.asset)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 26, height: 26)
                                .padding(4)
                                .background(Circle().fill(f.flagColor == c ? IOS3.dateBlue.opacity(0.18) : .clear))
                                .overlay(Circle().stroke(f.flagColor == c ? IOS3.dateBlue : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c.label)
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
            }
            HStack {
                Text(tr("优先级", "Priority")).font(RT.font(15, .bold))
                Spacer()
                IOS3Segmented(options: FollowUp.Priority.allCases.map { ($0, $0.label) }, selection: $f.priority)
                    .frame(width: 180)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
        }
    }

    private var reminderGroup: some View {
        RetroGroup(tr("提醒我", "Remind Me")) {
            row(tr("到时通知", "Notify")) {
                IOS3Switch(isOn: Binding(get: { hasReminder }, set: { on in
                    hasReminder = on
                    if on, f.reminder == nil { f.reminder = Self.quick(.tomorrowMorning) }
                }))
            }
            if hasReminder {
                DatePicker(tr("时间", "Time"),
                           selection: Binding(get: { f.reminder ?? Date() }, set: { f.reminder = $0 }),
                           displayedComponents: [.date, .hourAndMinute])
                    .font(RT.font(15, .bold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 46)
                quickRow([.inOneHour, .tonight, .tomorrowMorning, .nextMonday]) { f.reminder = Self.quick($0) }
            }
        }
    }

    private var deadlineGroup: some View {
        RetroGroup(tr("截止日期", "Deadline")) {
            row(tr("设截止日期", "Has Deadline")) {
                IOS3Switch(isOn: Binding(get: { hasDeadline }, set: { on in
                    hasDeadline = on
                    if on, f.deadline == nil { f.deadline = Self.quick(.endOfToday) }
                }))
            }
            if hasDeadline {
                DatePicker(tr("截止", "Due"),
                           selection: Binding(get: { f.deadline ?? Date() }, set: { f.deadline = $0 }),
                           displayedComponents: [.date, .hourAndMinute])
                    .font(RT.font(15, .bold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 46)
                quickRow([.endOfToday, .endOfTomorrow, .friday, .nextWeek]) { f.deadline = Self.quick($0) }
            }
        }
    }

    private var noteGroup: some View {
        RetroGroup(tr("备注", "Note")) {
            TextEditor(text: $f.note)
                .font(RT.font(15))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(HexColor.color("#FFF8C4").opacity(0.55))
                .overlay(alignment: .topLeading) {
                    if f.note.isEmpty {
                        Text(tr("要做什么、等谁回复、相关单号……", "What to do, who you're waiting on, reference numbers…"))
                            .font(RT.font(14))
                            .foregroundColor(IOS3.secondary)
                            .padding(.horizontal, 13)
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private var statusGroup: some View {
        RetroGroup("") {
            row(tr("已完成", "Done")) { IOS3Switch(isOn: $f.done) }
            Button { exportToReminders() } label: {
                HStack {
                    Image("fu-board").resizable().interpolation(.high).frame(width: 24, height: 24)
                    Text(f.reminderItemId == nil ? tr("添加到 iOS“提醒事项”", "Add to iOS Reminders")
                                                 : tr("更新 iOS“提醒事项”", "Update iOS Reminders"))
                        .font(RT.font(15, .bold))
                        .foregroundColor(IOS3.value)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if exists {
                Button { confirmRemove = true } label: {
                    HStack {
                        Text(tr("移除跟进", "Remove Follow-up")).font(RT.font(15, .bold)).foregroundColor(.red)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func quickRow(_ options: [Quick], set: @escaping (Quick) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { q in
                Button(q.label) { set(q) }
                    .buttonStyle(RetroButtonStyle(compact: true))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: 快捷时间

    enum Quick: Hashable {
        case inOneHour, tonight, tomorrowMorning, nextMonday, endOfToday, endOfTomorrow, friday, nextWeek

        var label: String {
            switch self {
            case .inOneHour: return tr("1 小时后", "In 1 hr")
            case .tonight: return tr("今晚", "Tonight")
            case .tomorrowMorning: return tr("明早", "Tmrw AM")
            case .nextMonday: return tr("下周一", "Next Mon")
            case .endOfToday: return tr("今天", "Today")
            case .endOfTomorrow: return tr("明天", "Tomorrow")
            case .friday: return tr("周五", "Friday")
            case .nextWeek: return tr("下周", "Next Wk")
            }
        }
    }

    static func quick(_ q: Quick) -> Date {
        let cal = Calendar.current
        let now = Date()
        func at(_ day: Date, _ h: Int, _ m: Int = 0) -> Date {
            cal.date(bySettingHour: h, minute: m, second: 0, of: day) ?? day
        }
        func next(weekday: Int) -> Date {
            var d = cal.date(byAdding: .day, value: 1, to: now)!
            while cal.component(.weekday, from: d) != weekday { d = cal.date(byAdding: .day, value: 1, to: d)! }
            return d
        }
        switch q {
        case .inOneHour: return now.addingTimeInterval(3600)
        case .tonight:
            let t = at(now, 20)
            return t > now ? t : at(cal.date(byAdding: .day, value: 1, to: now)!, 20)
        case .tomorrowMorning: return at(cal.date(byAdding: .day, value: 1, to: now)!, 9)
        case .nextMonday: return at(next(weekday: 2), 9)
        case .endOfToday: return at(now, 18)
        case .endOfTomorrow: return at(cal.date(byAdding: .day, value: 1, to: now)!, 18)
        case .friday:
            if cal.component(.weekday, from: now) == 6, at(now, 18) > now { return at(now, 18) }
            return at(next(weekday: 6), 18)
        case .nextWeek: return at(cal.date(byAdding: .day, value: 7, to: now)!, 18)
        }
    }

    // MARK: 保存

    private func normalized() -> FollowUp {
        var x = f
        if !hasReminder { x.reminder = nil }
        if !hasDeadline { x.deadline = nil }
        x.note = x.note.trimmingCharacters(in: .whitespacesAndNewlines)
        return x
    }

    private func save() {
        let x = normalized()
        let wasFlagged = store.item(initial.id)?.flagged ?? initial.summary.flagged
        store.save(x)
        if x.flagged != wasFlagged { syncFlag(x.flagged) }
        if x.reminderItemId != nil {
            Task { _ = try? await RemindersBridge.upsert(x) }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        var parts: [String] = []
        if x.flagged { parts.append(tr("旗标", "flag")) }
        if let r = x.reminder { parts.append(tr("提醒 ", "reminder ") + Fmt.compact(r)) }
        if let d = x.deadline { parts.append(tr("截止 ", "due ") + Fmt.compact(d)) }
        if !x.note.isEmpty { parts.append(tr("备注", "note")) }
        MailCenter.shared.showToast(MailToast(text: x.isEmpty ? tr("已移除跟进", "Follow-up removed")
                                                  : tr("已保存：", "Saved: ") + parts.joined(separator: " · "), undo: nil))
        dismiss()
    }

    private func syncFlag(_ on: Bool) {
        if let cb = onFlagChange {
            cb(on)
            return
        }
        guard let a = AccountStore.shared.accounts.first(where: { $0.id == initial.accountId }) else { return }
        let folder = initial.folder
        let uid = initial.summary.uid
        Task {
            _ = try? await MailCenter.shared.client(for: a, .interactive).perform {
                try await $0.store(folder, uids: [uid], flag: "\\Flagged", add: on)
            }
        }
    }

    private func exportToReminders() {
        busy = true
        Task {
            defer { busy = false }
            do {
                var x = normalized()
                x.reminderItemId = try await RemindersBridge.upsert(x)
                f.reminderItemId = x.reminderItemId
                message = tr("已添加到“提醒事项”。", "Added to Reminders.")
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

// MARK: - 跟进事项看板

struct FollowUpBoardView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case open, flagged, dated, notes, done
        var id: String { rawValue }
        var label: String {
            switch self {
            case .open: return tr("待办", "Open")
            case .flagged: return tr("旗标", "Flagged")
            case .dated: return tr("日期", "Dated")
            case .notes: return tr("备注", "Notes")
            case .done: return tr("已完成", "Done")
            }
        }
    }

    @ObservedObject private var store = FollowUpStore.shared
    @ObservedObject private var accounts = AccountStore.shared
    @EnvironmentObject private var settings: AppSettings
    @State private var filter: Filter = .open
    @State private var editing: FollowUp?
    @State private var importing = false
    @State private var message: String?
    @State private var confirmClear = false

    private var filtered: [FollowUp] {
        let list: [FollowUp]
        switch filter {
        case .open: list = store.all.filter { !$0.done }
        case .flagged: list = store.all.filter { !$0.done && $0.flagged }
        case .dated: list = store.all.filter { !$0.done && ($0.deadline != nil || $0.reminder != nil) }
        case .notes: list = store.all.filter { !$0.note.isEmpty }
        case .done: return store.all.filter(\.done).sorted { ($0.doneAt ?? $0.updated) > ($1.doneAt ?? $1.updated) }
        }
        return list.sorted { a, b in
            if a.sortDate != b.sortDate { return a.sortDate < b.sortDate }
            if a.priority != b.priority { return a.priority.rawValue > b.priority.rawValue }
            return a.summary.received > b.summary.received
        }
    }

    private struct Bucket: Identifiable {
        let title: String
        let items: [FollowUp]
        var id: String { title }
    }

    private var buckets: [Bucket] {
        let list = filtered
        if filter == .done || filter == .notes { return list.isEmpty ? [] : [Bucket(title: "", items: list)] }
        let cal = Calendar.current
        let now = Date()
        var overdue: [FollowUp] = [], today: [FollowUp] = [], tomorrow: [FollowUp] = [], week: [FollowUp] = [], later: [FollowUp] = [], none: [FollowUp] = []
        for f in list {
            guard let d = f.deadline ?? f.reminder else { none.append(f); continue }
            if f.isOverdue || (f.deadline == nil && d < now) { overdue.append(f) }
            else if cal.isDateInToday(d) { today.append(f) }
            else if cal.isDateInTomorrow(d) { tomorrow.append(f) }
            else if d < now.addingTimeInterval(7 * 86400) { week.append(f) }
            else { later.append(f) }
        }
        return [
            Bucket(title: tr("已逾期", "Overdue"), items: overdue),
            Bucket(title: tr("今天", "Today"), items: today),
            Bucket(title: tr("明天", "Tomorrow"), items: tomorrow),
            Bucket(title: tr("7 天内", "Next 7 Days"), items: week),
            Bucket(title: tr("以后", "Later"), items: later),
            Bucket(title: tr("无日期", "No Date"), items: none),
        ].filter { !$0.items.isEmpty }
    }

    var body: some View {
        RetroScreen(title: tr("跟进事项", "Follow-ups"), back: tr("邮箱", "Mailboxes")) {
            Button(tr("导入旗标", "Import")) { importFlags() }
                .buttonStyle(BarButtonStyle())
                .disabled(importing)
        } content: {
            VStack(spacing: 0) {
                IOS3Segmented(options: Filter.allCases.map { ($0, $0.label) }, selection: $filter)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                ScrollView {
                    if buckets.isEmpty {
                        emptyState
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(buckets) { b in
                                if !b.title.isEmpty {
                                    Text(b.title + "  \(b.items.count)")
                                        .font(RT.font(16, .bold))
                                        .foregroundColor(b.title == tr("已逾期", "Overdue") ? HexColor.color("#C0281C") : IOS3.groupHeader)
                                        .shadow(color: IOS3.groupHeaderShadow, radius: 0, x: 0, y: 1)
                                        .padding(.horizontal, 8)
                                        .padding(.top, 12)
                                }
                                GroupedBox {
                                    ForEach(Array(b.items.enumerated()), id: \.element.id) { i, f in
                                        FollowUpRow(item: f, last: i == b.items.count - 1, folderName: folderName(f)) {
                                            editing = f
                                        }
                                    }
                                }
                            }
                            if filter == .done {
                                Button(tr("清除已完成", "Clear Done")) { confirmClear = true }
                                    .buttonStyle(RetroButtonStyle(compact: true))
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 16)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .busyOverlay(importing, tr("正在查找服务器上已加旗标的邮件…", "Looking for flagged mail on the server…"))
        .retroAlert($message)
        .sheet(item: $editing) { f in
            FollowUpEditor(item: f)
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
        }
        .ios3ActionSheet(isPresented: $confirmClear, actions: [
            SheetAction(tr("清除全部已完成", "Clear All Done"), role: .destructive) {
                for f in store.all where f.done { store.remove(f.id) }
            },
        ])
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image("fu-notes")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 88, height: 88)
                .padding(.top, 40)
            Text(filter == .done ? tr("还没有已完成的事项", "Nothing done yet") : tr("没有待跟进的邮件", "No follow-ups"))
                .font(RT.font(18, .bold))
                .foregroundColor(IOS3.groupHeader)
                .shadow(color: IOS3.groupHeaderShadow, radius: 0, x: 0, y: 1)
            Text(tr("打开一封邮件，点卡片底部的“更多 → 跟进…”，就可以加旗标、设提醒和截止日期、写备注。到时间会通知你，事项都汇总在这里。\n点右上角“导入旗标”，可以把在电脑或网页邮箱里加了旗标的邮件也拿过来。",
                    "Open a message and tap More → Follow Up… to flag it, set a reminder or deadline, or add a note. You'll be notified on time, and everything is collected here.\nTap Import to bring in mail you flagged on other devices."))
                .font(RT.font(14))
                .foregroundColor(IOS3.groupHeader)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
    }

    private func folderName(_ f: FollowUp) -> String {
        let folders = MailCenter.shared.folders[f.accountId] ?? []
        let name = folders.first { $0.path == f.folder }?.displayName ?? IMAPUTF7.decode(f.folder)
        if accounts.accounts.count > 1, let a = accounts.accounts.first(where: { $0.id == f.accountId }) {
            return (a.name.isEmpty ? a.email : a.name) + " · " + name
        }
        return name
    }

    private func importFlags() {
        importing = true
        Task {
            defer { importing = false }
            var added = 0
            for a in accounts.accounts {
                let path = MailCenter.shared.folder(a, role: .inbox)?.path ?? "INBOX"
                let c = MailCenter.shared.client(for: a, .background)
                if let found = try? await c.perform({ try await $0.searchFlagged(path, limit: 60) }) {
                    added += store.importServerFlags(a, folder: path, messages: found)
                }
            }
            message = added > 0 ? tr("导入了 \(added) 封加旗标的邮件。", "Imported \(added) flagged messages.")
                                : tr("没有新的加旗标邮件。", "No new flagged messages.")
        }
    }
}

struct FollowUpRow: View {
    let item: FollowUp
    let last: Bool
    let folderName: String
    let onEdit: () -> Void
    @ObservedObject private var store = FollowUpStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { store.setDone(item.id, !item.done) }
            } label: {
                ZStack {
                    Circle().stroke(item.done ? IOS3.dateBlue : IOS3.chevron, lineWidth: 2)
                        .frame(width: 22, height: 22)
                    if item.done {
                        Circle().fill(IOS3.selection).frame(width: 22, height: 22)
                        Text("✓").font(.system(size: 13, weight: .heavy)).foregroundColor(.white)
                    }
                }
                .frame(width: 30, height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.done ? tr("标为未完成", "Mark not done") : tr("标为完成", "Mark done"))

            NavigationLink(value: Route.followUpMessage(item.id)) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        if item.flagged {
                            Image(item.flagColor.asset).resizable().interpolation(.high).frame(width: 16, height: 16)
                        }
                        if item.priority == .high {
                            Text("!!").font(RT.font(14, .bold)).foregroundColor(HexColor.color("#C0281C"))
                        }
                        Text(item.subject)
                            .font(RT.font(15, .bold))
                            .strikethrough(item.done)
                            .foregroundColor(item.done ? IOS3.secondary : .ink)
                            .lineLimit(2)
                    }
                    Text(item.sender + " · " + folderName)
                        .font(RT.font(12))
                        .foregroundColor(IOS3.secondary)
                        .lineLimit(1)
                    if !item.note.isEmpty {
                        Text(item.note)
                            .font(RT.font(13))
                            .foregroundColor(HexColor.color("#5A4A00"))
                            .lineLimit(3)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 4).fill(HexColor.color("#FFF4A8")))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(HexColor.color("#E2CF5A"), lineWidth: 1))
                    }
                    if item.deadline != nil || item.reminder != nil {
                        HStack(spacing: 6) {
                            if let d = item.deadline { chip(tr("截止 ", "Due ") + Fmt.compact(d), color: deadlineColor(d)) }
                            if let r = item.reminder { chip("⏰ " + Fmt.compact(r), color: r < Date() ? IOS3.secondary : IOS3.value) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onEdit) {
                Text("i")
                    .font(.system(size: 14, weight: .heavy, design: .serif))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(IOS3.selection))
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("编辑跟进", "Edit follow-up"))
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(IOS3.separator).frame(height: 1) }
        }
        .opacity(item.done ? 0.75 : 1)
    }

    private func deadlineColor(_ d: Date) -> Color {
        if item.done { return IOS3.secondary }
        if d < Date() { return HexColor.color("#C0281C") }
        if Calendar.current.isDateInToday(d) { return HexColor.color("#D9822B") }
        return IOS3.dateBlue
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(RT.font(11, .bold))
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
    }
}

// MARK: - 从看板打开邮件

struct FollowUpMessageView: View {
    let id: String
    @ObservedObject private var store = FollowUpStore.shared

    var body: some View {
        if let f = store.item(id), let a = AccountStore.shared.accounts.first(where: { $0.id == f.accountId }) {
            FollowUpConversationHost(item: f, account: a)
        } else {
            RetroScreen(title: tr("跟进", "Follow Up"), back: tr("返回", "Back")) {
                EmptyView()
            } content: {
                Text(tr("找不到这封邮件或它所属的账户。", "This message or its account is no longer available."))
                    .font(RT.font(15))
                    .foregroundColor(IOS3.groupHeader)
                    .padding(20)
            }
        }
    }
}

private struct FollowUpConversationHost: View {
    let item: FollowUp
    let account: MailAccount

    var body: some View {
        let folder = MailCenter.shared.folders[account.id]?.first { $0.path == item.folder }
            ?? MailFolder(path: item.folder, delimiter: nil, flags: [])
        MessageHostView(account: account, folder: folder, summary: item.summary)
    }
}

/// 单独打开一封邮件（来自通知或跟进事项），复用会话页。
struct MessageHostView: View {
    let summary: MessageSummary
    @StateObject private var list: MessageListModel

    init(account: MailAccount, folder: MailFolder, summary: MessageSummary) {
        self.summary = summary
        _list = StateObject(wrappedValue: MessageListModel(account: account, folder: folder))
    }

    var body: some View {
        ConversationView(list: list, conversation: Conversation(messages: [summary]))
    }
}
