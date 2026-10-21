import SwiftUI
import EventKit
import EventKitUI

// MARK: - 日历数据

@MainActor
final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()
    let store = EKEventStore()

    @Published private(set) var authorized = false
    @Published private(set) var denied = false
    @Published private(set) var calendars: [EKCalendar] = []
    /// 某天 0 点 → 当天的日程
    @Published private(set) var byDay: [Date: [EKEvent]] = [:]
    @Published var hidden: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(hidden), forKey: "calendar.hidden")
            reload()
        }
    }

    private var range: (Date, Date)?
    private var observer: NSObjectProtocol?

    private init() {
        hidden = Set(UserDefaults.standard.stringArray(forKey: "calendar.hidden") ?? [])
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in CalendarStore.shared.reload() }
        }
        updateStatus()
    }

    private func updateStatus() {
        let st = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, *) {
            authorized = st == .fullAccess
        } else {
            authorized = st == .authorized
        }
        denied = st == .denied || st == .restricted
    }

    func requestAccess() async {
        if #available(iOS 17.0, *) {
            _ = try? await store.requestFullAccessToEvents()
        } else {
            _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                store.requestAccess(to: .event) { ok, _ in c.resume(returning: ok) }
            }
        }
        updateStatus()
        reload()
    }

    /// 读取一段时间的日程（月视图前后各多读一个月）。
    func load(from start: Date, to end: Date) {
        range = (start, end)
        reload()
    }

    func reload() {
        guard authorized else { return }
        calendars = store.calendars(for: .event).sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        guard let r = range else { return }
        let start = r.0, end = r.1
        let visible = calendars.filter { !hidden.contains($0.calendarIdentifier) }
        guard !visible.isEmpty else { byDay = [:]; return }
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: visible)
        let events = store.events(matching: pred)
        var out: [Date: [EKEvent]] = [:]
        let cal = Calendar.current
        for e in events {
            // 跨天的日程在每一天都显示
            var day = cal.startOfDay(for: e.startDate)
            let last = cal.startOfDay(for: max(e.startDate, e.endDate.addingTimeInterval(-1)))
            var guardCount = 0
            while day <= last && guardCount < 62 {
                out[day, default: []].append(e)
                day = cal.date(byAdding: .day, value: 1, to: day) ?? last.addingTimeInterval(86400)
                guardCount += 1
            }
        }
        for k in out.keys {
            out[k]?.sort { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.startDate < b.startDate
            }
        }
        byDay = out
    }

    func events(on day: Date) -> [EKEvent] {
        byDay[Calendar.current.startOfDay(for: day)] ?? []
    }

    /// 首页显示的一行：今天几个日程、下一个是什么。
    var todayLine: String {
        guard authorized else { return tr("查看和安排会议、日程", "See and plan your meetings") }
        let now = Date()
        let today = events(on: now).filter { !$0.isAllDay }
        if let next = today.first(where: { $0.endDate > now }) {
            let t = Fmt.string(next.startDate, zh: "HH:mm", en: "h:mm a")
            return tr("今天 \(today.count) 个日程 · 下一个 \(t) \(next.title ?? "")", "\(today.count) today · next \(t) \(next.title ?? "")")
        }
        return today.isEmpty ? tr("今天没有日程", "Nothing scheduled today") : tr("今天的日程都结束了", "Today's events are over")
    }

    var todayCount: Int { events(on: Date()).filter { !$0.isAllDay && $0.endDate > Date() }.count }
}

// MARK: - 日历页面（iPhone OS 3 日历的样子）

struct CalendarView: View {
    enum Mode: String, CaseIterable { case month, list }

    @ObservedObject private var cal = CalendarStore.shared
    @ObservedObject private var followUps = FollowUpStore.shared
    @EnvironmentObject private var settings: AppSettings
    @State private var mode: Mode = .month
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var selected = Calendar.current.startOfDay(for: Date())
    @State private var showEvent: EKEvent?
    @State private var newEvent: NewEventRequest?
    @State private var showCalendars = false

    private var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = settings.isEnglish ? 1 : 2
        return c
    }

    var body: some View {
        RetroScreen(title: tr("日历", "Calendar"), back: tr("邮箱", "Mailboxes")) {
            Button {
                newEvent = NewEventRequest(start: defaultStart(on: selected))
            } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .bold))
            }
            .buttonStyle(BarButtonStyle())
            .disabled(!cal.authorized)
        } content: {
            VStack(spacing: 0) {
                if !cal.authorized {
                    accessPrompt
                } else {
                    IOS3Segmented(options: [(Mode.month, tr("月", "Month")), (Mode.list, tr("列表", "List"))], selection: $mode)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(LinearGradient(stops: IOS3.searchStops, startPoint: .top, endPoint: .bottom))
                    if mode == .month {
                        monthHeader
                        monthGrid
                        dayList
                    } else {
                        agenda
                    }
                    toolbar
                }
            }
        }
        .task {
            if !cal.authorized && !cal.denied { await cal.requestAccess() }
            loadRange()
        }
        .onChange(of: month) { _ in loadRange() }
        .sheet(item: Binding(get: { showEvent.map(EventBox.init) }, set: { showEvent = $0?.event })) { box in
            EventDetailView(event: box.event, store: cal.store)
                .ignoresSafeArea()
        }
        .sheet(item: $newEvent) { req in
            NewEventView(request: req, store: cal.store)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $showCalendars) {
            CalendarPicker()
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
        }
    }

    private func loadRange() {
        let start = calendar.date(byAdding: .month, value: -1, to: month) ?? month
        let end = calendar.date(byAdding: .month, value: 3, to: month) ?? month
        cal.load(from: start, to: end)
    }

    private func defaultStart(on day: Date) -> Date {
        let now = Date()
        if calendar.isDate(day, inSameDayAs: now) {
            let next = calendar.date(byAdding: .hour, value: 1, to: now) ?? now
            return calendar.date(bySetting: .minute, value: 0, of: next) ?? next
        }
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
    }

    private var accessPrompt: some View {
        VStack(spacing: 14) {
            Image("mbx-calendar").resizable().interpolation(.high).frame(width: 80, height: 80).padding(.top, 40)
            Text(cal.denied ? tr("没有日历权限", "No Calendar Access") : tr("需要访问日历", "Calendar Access Needed"))
                .font(RT.font(18, .bold))
                .foregroundColor(IOS3.groupHeader)
            Text(cal.denied
                 ? tr("请到 iOS 设置 → RetroMail → 日历，选择“完全访问”。这里会显示 iPhone 上所有日历（iCloud、Exchange、Google 等）的会议安排。",
                      "Go to iOS Settings → RetroMail → Calendars and choose Full Access. All calendars on your iPhone (iCloud, Exchange, Google…) are shown here.")
                 : tr("RetroMail 会显示 iPhone 上所有日历（iCloud、Exchange、Google 等）的会议安排，也可以直接新建和修改。",
                      "RetroMail shows meetings from every calendar on your iPhone (iCloud, Exchange, Google…) and lets you add and edit them."))
                .font(RT.font(14))
                .foregroundColor(IOS3.groupHeader)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            if cal.denied {
                Button(tr("打开设置", "Open Settings")) {
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                }
                .buttonStyle(RetroButtonStyle(isDefault: true))
            } else {
                Button(tr("允许访问", "Allow Access")) { Task { await cal.requestAccess(); loadRange() } }
                    .buttonStyle(RetroButtonStyle(isDefault: true))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 月视图

    private var monthHeader: some View {
        VStack(spacing: 2) {
            HStack {
                Button { step(-1) } label: {
                    Image(systemName: "arrowtriangle.left.fill").font(.system(size: 14))
                        .frame(width: 48, height: 36)
                        .contentShape(Rectangle())
                }
                Spacer()
                Text(Fmt.string(month, zh: "yyyy年 M月", en: "MMMM yyyy"))
                    .font(RT.font(20, .bold))
                    .foregroundColor(HexColor.color("#2E3640"))
                    .shadow(color: .white.opacity(0.8), radius: 0, x: 0, y: 1)
                Spacer()
                Button { step(1) } label: {
                    Image(systemName: "arrowtriangle.right.fill").font(.system(size: 14))
                        .frame(width: 48, height: 36)
                        .contentShape(Rectangle())
                }
            }
            .foregroundColor(HexColor.color("#56606D"))
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { d in
                    Text(d).font(RT.font(10, .bold)).foregroundColor(HexColor.color("#4A525C")).frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 3)
        }
        .padding(.top, 2)
        .background(LinearGradient(colors: [HexColor.color("#F4F4F6"), HexColor.color("#CCCCD2")], startPoint: .top, endPoint: .bottom))
    }

    private var weekdaySymbols: [String] {
        let syms = settings.isEnglish ? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] : ["日", "一", "二", "三", "四", "五", "六"]
        let first = calendar.firstWeekday - 1
        return Array(syms[first...] + syms[..<first])
    }

    private var gridDays: [Date] {
        let first = month
        let wd = calendar.component(.weekday, from: first)
        let offset = (wd - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -offset, to: first) ?? first
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var monthGrid: some View {
        let days = gridDays
        return VStack(spacing: 0) {
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        dayCell(days[row * 7 + col])
                    }
                }
            }
        }
        .background(HexColor.color("#DADCE2"))
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.width < -40 { step(1) } else if v.translation.width > 40 { step(-1) }
        })
    }

    private func dayCell(_ day: Date) -> some View {
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isSel = calendar.isDate(day, inSameDayAs: selected)
        let isToday = calendar.isDateInToday(day)
        let evs = cal.events(on: day)
        let due = followUps.open.contains { f in f.deadline.map { calendar.isDate($0, inSameDayAs: day) } ?? false }
        return Button {
            selected = calendar.startOfDay(for: day)
            if !inMonth { month = calendar.date(from: calendar.dateComponents([.year, .month], from: day)) ?? month }
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(RT.font(17, .bold))
                    .foregroundColor(isSel ? .white : (inMonth ? HexColor.color("#2F3740") : HexColor.color("#8C929B")))
                    .shadow(color: isSel ? .black.opacity(0.4) : .white.opacity(0.7), radius: 0, x: 0, y: isSel ? -1 : 1)
                HStack(spacing: 2) {
                    ForEach(Array(evs.prefix(3).enumerated()), id: \.offset) { _, e in
                        Circle().fill(isSel ? Color.white : Color(cgColor: e.calendar?.cgColor ?? UIColor.gray.cgColor)).frame(width: 5, height: 5)
                    }
                    if due {
                        Circle().fill(isSel ? Color.white : HexColor.color("#E8740C")).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                ZStack {
                    if isSel {
                        LinearGradient(colors: [HexColor.color("#5F8FD8"), HexColor.color("#2B5DB8")], startPoint: .top, endPoint: .bottom)
                    } else if isToday {
                        LinearGradient(colors: [HexColor.color("#7A8DA6"), HexColor.color("#5D6E86")], startPoint: .top, endPoint: .bottom).opacity(0.35)
                    } else {
                        LinearGradient(colors: inMonth ? [HexColor.color("#E9EAEE"), HexColor.color("#D9DBE1")]
                                                       : [HexColor.color("#D4D6DC"), HexColor.color("#C6C9D0")], startPoint: .top, endPoint: .bottom)
                    }
                }
            )
            .overlay(Rectangle().stroke(HexColor.color("#A9AEB6"), lineWidth: 0.5))
            .overlay(isToday && !isSel ? Rectangle().stroke(HexColor.color("#2B5DB8"), lineWidth: 2).padding(1) : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Fmt.long(day) + (evs.isEmpty ? "" : tr("，\(evs.count) 个日程", ", \(evs.count) events")))
    }

    private func step(_ d: Int) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.easeOut(duration: 0.15)) {
            month = calendar.date(byAdding: .month, value: d, to: month) ?? month
            if !calendar.isDate(selected, equalTo: month, toGranularity: .month) {
                selected = calendar.isDate(Date(), equalTo: month, toGranularity: .month) ? calendar.startOfDay(for: Date()) : month
            }
        }
    }

    private var dayList: some View {
        let evs = cal.events(on: selected)
        let fus = followUps.open.filter { f in f.deadline.map { calendar.isDate($0, inSameDayAs: selected) } ?? false }
        return ScrollView {
            VStack(spacing: 0) {
                if evs.isEmpty && fus.isEmpty {
                    Text(tr("没有日程", "No Events"))
                        .font(RT.font(17, .bold))
                        .foregroundColor(IOS3.secondary)
                        .padding(.top, 24)
                } else {
                    ForEach(evs, id: \.eventIdentifier) { e in eventRow(e) }
                    ForEach(fus) { f in followUpRow(f) }
                }
            }
        }
        .background(IOS3.cell)
    }

    private func eventRow(_ e: EKEvent) -> some View {
        Button { showEvent = e } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .trailing, spacing: 1) {
                    if e.isAllDay {
                        Text(tr("全天", "all-day")).font(RT.font(13, .bold))
                    } else {
                        Text(Fmt.string(e.startDate, zh: "HH:mm", en: "h:mm a")).font(RT.font(14, .bold))
                        Text(Fmt.string(e.endDate, zh: "HH:mm", en: "h:mm a")).font(RT.font(12)).foregroundColor(IOS3.secondary)
                    }
                }
                .frame(width: 58, alignment: .trailing)
                RoundedRectangle(cornerRadius: 2).fill(Color(cgColor: e.calendar?.cgColor ?? UIColor.gray.cgColor)).frame(width: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title ?? tr("（无标题）", "(No Title)")).font(RT.font(16, .bold)).lineLimit(2)
                    if let loc = e.location, !loc.isEmpty {
                        Text(loc).font(RT.font(13)).foregroundColor(IOS3.secondary).lineLimit(1)
                    }
                    if let n = e.attendees?.count, n > 0 {
                        Text(tr("\(n) 位参与者", "\(n) attendees")).font(RT.font(12)).foregroundColor(IOS3.secondary)
                    }
                }
                Spacer(minLength: 0)
                Chevron()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(InvertOnPressStyle())
        .overlay(alignment: .bottom) { Rectangle().fill(IOS3.separator).frame(height: 1) }
    }

    private func followUpRow(_ f: FollowUp) -> some View {
        NavigationLink(value: Route.followUpMessage(f.id)) {
            HStack(spacing: 10) {
                Text(f.deadline.map { Fmt.string($0, zh: "HH:mm", en: "h:mm a") } ?? "")
                    .font(RT.font(14, .bold))
                    .frame(width: 58, alignment: .trailing)
                Image(f.flagColor.asset).resizable().interpolation(.high).frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("截止：", "Due: ") + f.subject).font(RT.font(15, .bold)).lineLimit(2)
                    Text(f.sender).font(RT.font(12)).foregroundColor(IOS3.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Chevron()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(InvertOnPressStyle())
        .overlay(alignment: .bottom) { Rectangle().fill(IOS3.separator).frame(height: 1) }
    }

    // MARK: 列表视图

    private var agenda: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let days = (0..<45).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
            .filter { !cal.events(on: $0).isEmpty }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if days.isEmpty {
                    Text(tr("接下来 45 天没有日程", "Nothing in the next 45 days"))
                        .font(RT.font(16, .bold))
                        .foregroundColor(IOS3.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                }
                ForEach(days, id: \.self) { d in
                    Section {
                        ForEach(cal.events(on: d), id: \.eventIdentifier) { e in eventRow(e) }
                    } header: {
                        PlainSectionHeader(title: Fmt.string(d, zh: "M月d日 EEEE", en: "EEEE, MMM d") + (calendar.isDateInToday(d) ? tr("（今天）", " (Today)") : ""))
                    }
                }
            }
        }
        .background(IOS3.cell)
        .onAppear {
            cal.load(from: today, to: calendar.date(byAdding: .day, value: 46, to: today) ?? today)
        }
        .onDisappear { loadRange() }
    }

    private var toolbar: some View {
        IOS3Toolbar {
            Button(tr("今天", "Today")) {
                withAnimation(.easeOut(duration: 0.15)) {
                    month = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? month
                    selected = calendar.startOfDay(for: Date())
                    mode = .month
                }
            }
            .buttonStyle(BarButtonStyle())
            .frame(width: 70)
            ToolbarStatus(text: Fmt.string(selected, zh: "M月d日 EEE", en: "EEE, MMM d"))
            Button(tr("日历", "Calendars")) { showCalendars = true }
                .buttonStyle(BarButtonStyle())
                .frame(width: 70)
        }
    }
}

private struct EventBox: Identifiable {
    let event: EKEvent
    var id: String { event.eventIdentifier ?? UUID().uuidString }
}

/// 选择显示哪些日历。
struct CalendarPicker: View {
    @ObservedObject private var cal = CalendarStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            IOS3NavBar(title: tr("日历", "Calendars")) {
                EmptyView()
            } trailing: {
                Button(tr("完成", "Done")) { dismiss() }.buttonStyle(BarButtonStyle(kind: .done))
            }
            ScrollView {
                let groups = Dictionary(grouping: cal.calendars) { $0.source?.title ?? "" }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(groups.keys.sorted(), id: \.self) { src in
                        RetroGroup(src) {
                            ForEach(groups[src] ?? [], id: \.calendarIdentifier) { c in
                                Button {
                                    if cal.hidden.contains(c.calendarIdentifier) { cal.hidden.remove(c.calendarIdentifier) }
                                    else { cal.hidden.insert(c.calendarIdentifier) }
                                } label: {
                                    HStack {
                                        Circle().fill(Color(cgColor: c.cgColor)).frame(width: 12, height: 12)
                                        Text(c.title).font(RT.font(16, .bold))
                                        Spacer()
                                        if !cal.hidden.contains(c.calendarIdentifier) {
                                            Text("✓").font(.system(size: 17, weight: .heavy)).foregroundColor(IOS3.value)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .foregroundColor(.ink)
        .background(PinstripeBackground().ignoresSafeArea())
    }
}

// MARK: - 系统的日程详情 / 新建界面

struct EventDetailView: UIViewControllerRepresentable {
    let event: EKEvent
    let store: EKEventStore
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = EKEventViewController()
        vc.event = event
        vc.allowsEditing = true
        vc.allowsCalendarPreview = true
        vc.delegate = context.coordinator
        vc.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: context.coordinator, action: #selector(Coordinator.close))
        return UINavigationController(rootViewController: vc)
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, EKEventViewDelegate {
        let parent: EventDetailView
        init(_ p: EventDetailView) { parent = p }
        @objc func close() { parent.dismiss() }
        func eventViewController(_ controller: EKEventViewController, didCompleteWith action: EKEventViewAction) {
            parent.dismiss()
        }
    }
}

struct NewEventRequest: Identifiable {
    let id = UUID()
    var title = ""
    var notes = ""
    var location = ""
    var url: URL?
    var start: Date
    var minutes = 60
}

struct NewEventView: UIViewControllerRepresentable {
    let request: NewEventRequest
    let store: EKEventStore
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let vc = EKEventEditViewController()
        vc.eventStore = store
        let ev = EKEvent(eventStore: store)
        ev.title = request.title
        ev.startDate = request.start
        ev.endDate = request.start.addingTimeInterval(Double(request.minutes) * 60)
        if !request.notes.isEmpty { ev.notes = request.notes }
        if !request.location.isEmpty { ev.location = request.location }
        ev.url = request.url
        if let c = store.defaultCalendarForNewEvents { ev.calendar = c }
        vc.event = ev
        vc.editViewDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let parent: NewEventView
        init(_ p: NewEventView) { parent = p }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            if action == .saved {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                Task { @MainActor in
                    MailCenter.shared.showToast(MailToast(text: tr("已添加到日历", "Added to Calendar"), undo: nil))
                    CalendarStore.shared.reload()
                }
            }
            parent.dismiss()
        }
    }
}
