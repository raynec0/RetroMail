import SwiftUI
import UIKit

/// 经典 Mac OS × 古早 iOS：黑白线框、方块按钮、硬阴影、轻微光泽渐变。
enum RT {
    static func font(_ size: CGFloat = 15, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - 背景与线条

struct DitherBackground: View {
    @Environment(\.colorScheme) private var scheme

    private static func pattern(dark: Bool) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: fmt).image { ctx in
            (dark ? UIColor(white: 0.04, alpha: 1) : UIColor.white).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            (dark ? UIColor(white: 0.30, alpha: 1) : UIColor.black).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            ctx.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
        }
    }

    private static let light = pattern(dark: false)
    private static let dark = pattern(dark: true)

    var body: some View {
        Rectangle()
            .fill(ImagePaint(image: Image(uiImage: scheme == .dark ? Self.dark : Self.light), scale: 1))
            .ignoresSafeArea()
    }
}

struct HLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

struct RetroDivider: View {
    var dotted = false

    var body: some View {
        if dotted {
            HLine().stroke(Color.ink, style: StrokeStyle(lineWidth: 1, dash: [1, 2])).frame(height: 1)
        } else {
            Rectangle().fill(Color.ink).frame(height: 1)
        }
    }
}

/// 古早 iOS 的光泽底：上亮下暗。
struct GlossFill: View {
    var body: some View {
        LinearGradient(colors: [.paper, .mist, .shade.opacity(0.55)], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - 窗口

struct StripedTitleBar: View {
    let title: String
    var onClose: (() -> Void)?

    var body: some View {
        ZStack {
            VStack(spacing: 1) {
                ForEach(0..<6, id: \.self) { _ in
                    Rectangle().fill(Color.ink).frame(height: 1)
                }
            }
            .padding(.horizontal, 3)

            HStack(spacing: 0) {
                if let onClose = onClose {
                    Button(action: onClose) {
                        Rectangle()
                            .fill(Color.paper)
                            .frame(width: 14, height: 14)
                            .overlay(Rectangle().stroke(Color.ink, lineWidth: 1))
                            .padding(.horizontal, 3)
                            .background(Color.paper)
                            .frame(width: 46, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tr("关闭", "Close"))
                }
                Spacer()
            }

            Text(title)
                .font(RT.font(14, .bold))
                .foregroundColor(.ink)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .background(Color.paper)
                .padding(.horizontal, 50)
        }
        .frame(height: 26)
        .background(Color.paper)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.ink).frame(height: 1) }
    }
}

struct RetroWindow<Content: View>: View {
    let title: String
    var onClose: (() -> Void)?
    var fill: Bool
    var shadow: Bool
    let content: Content

    init(title: String, onClose: (() -> Void)? = nil, fill: Bool = true, shadow: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.onClose = onClose
        self.fill = fill
        self.shadow = shadow
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            StripedTitleBar(title: title, onClose: onClose)
            if fill {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Color.paper)
            } else {
                content
                    .frame(maxWidth: .infinity, alignment: .top)
                    .background(Color.paper)
            }
        }
        .overlay(Rectangle().stroke(Color.ink, lineWidth: 1))
        .background(Rectangle().fill(Color.ink).offset(x: shadow ? 3 : 0, y: shadow ? 3 : 0))
    }
}

/// 全屏窗口：关闭框 = 返回。
struct RetroScreen<Content: View>: View {
    let title: String
    var showClose: Bool
    let content: Content
    @Environment(\.dismiss) private var dismiss

    init(title: String, showClose: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.showClose = showClose
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            StripedTitleBar(title: title, onClose: showClose ? { dismiss() } : nil)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundColor(.ink)
        .background(Color.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - 按钮：长方形（文字）

struct RetroButtonStyle: ButtonStyle {
    var isDefault = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        RetroButtonBody(configuration: configuration, isDefault: isDefault, compact: compact)
    }
}

private struct RetroButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isDefault: Bool
    let compact: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let pressed = configuration.isPressed
        let depth: CGFloat = compact ? 2 : 3
        configuration.label
            .font(RT.font(compact ? 13 : 15, .bold))
            .lineLimit(1)
            .padding(.horizontal, compact ? 10 : 16)
            .padding(.vertical, compact ? 6 : 8)
            .foregroundColor(pressed ? .paper : .ink)
            .background {
                if pressed { Color.ink } else { GlossFill() }
            }
            .overlay(alignment: .top) {
                if !pressed {
                    Rectangle().fill(Color.paper.opacity(0.9)).frame(height: 1).padding(.horizontal, 2).padding(.top, 2)
                }
            }
            .overlay(Rectangle().stroke(Color.ink, lineWidth: isDefault ? 3 : 1.5))
            .background(Rectangle().fill(Color.ink).offset(x: pressed ? 0 : depth, y: pressed ? 0 : depth))
            .offset(x: pressed ? depth : 0, y: pressed ? depth : 0)
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }
}

// MARK: - 按钮：方块 + 文字（古早 iOS 工具栏风格）

struct TileStyle: ButtonStyle {
    var active = false
    var depth: CGFloat = 2.5

    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration, active: active, depth: depth)
    }
}

private struct TileBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    let depth: CGFloat
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let pressed = configuration.isPressed
        let on = pressed || active
        configuration.label
            .foregroundColor(on ? .paper : .ink)
            .background {
                if on { Color.ink } else { GlossFill() }
            }
            .overlay(alignment: .top) {
                if !on {
                    Rectangle().fill(Color.paper.opacity(0.9)).frame(height: 1).padding(.horizontal, 2).padding(.top, 2)
                }
            }
            .overlay(Rectangle().stroke(Color.ink, lineWidth: 1.5))
            .background(Rectangle().fill(Color.ink).offset(x: pressed ? 0 : depth, y: pressed ? 0 : depth))
            .offset(x: pressed ? depth : 0, y: pressed ? depth : 0)
            .opacity(enabled ? 1 : 0.3)
            .contentShape(Rectangle())
    }
}

struct TileButton: View {
    var symbol: String?
    var glyph: String?
    var glyphFont: Font?
    let label: String
    var active = false
    var size: CGFloat = 50
    let action: () -> Void

    init(symbol: String, label: String, active: Bool = false, size: CGFloat = 50, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.active = active
        self.size = size
        self.action = action
    }

    init(glyph: String, font: Font? = nil, label: String, active: Bool = false, size: CGFloat = 50, action: @escaping () -> Void) {
        self.glyph = glyph
        self.glyphFont = font
        self.label = label
        self.active = active
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Group {
                    if let s = symbol {
                        Image(systemName: s).font(.system(size: size * 0.36, weight: .semibold))
                    } else {
                        Text(glyph ?? "").font(glyphFont ?? .system(size: size * 0.38, weight: .bold, design: .serif))
                    }
                }
                .frame(height: size * 0.48)
                Text(label)
                    .font(RT.font(size > 54 ? 11 : 9.5, .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 2)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(TileStyle(active: active))
    }
}

/// 列表行：按下时反色。
struct InvertOnPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(configuration.isPressed ? .paper : .ink)
            .background(configuration.isPressed ? Color.ink : Color.paper)
    }
}

// MARK: - 表单控件

struct RetroField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var secure = false
    var keyboard: UIKeyboardType = .default
    var labelWidth: CGFloat = 80

    var body: some View {
        HStack(spacing: 6) {
            if !label.isEmpty {
                Text(label)
                    .font(RT.font(13, .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: labelWidth, alignment: .trailing)
            }
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(RT.font(14))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(Color.paper)
            .overlay(Rectangle().stroke(Color.ink, lineWidth: 1))
            .background(Rectangle().fill(Color.ink).offset(x: 1.5, y: 1.5))
        }
        .foregroundColor(.ink)
    }
}

struct RetroCheckbox: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Rectangle().fill(Color.paper)
                    Rectangle().stroke(Color.ink, lineWidth: 1)
                    if isOn {
                        Path { p in
                            p.move(to: CGPoint(x: 2, y: 2))
                            p.addLine(to: CGPoint(x: 12, y: 12))
                            p.move(to: CGPoint(x: 12, y: 2))
                            p.addLine(to: CGPoint(x: 2, y: 12))
                        }
                        .stroke(Color.ink, lineWidth: 1.5)
                    }
                }
                .frame(width: 14, height: 14)
                .padding(.top, 2)
                Text(label)
                    .font(RT.font(13))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundColor(.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 通用单选组。
struct RetroRadio<T: Hashable>: View {
    let label: String
    let options: [(T, String)]
    @Binding var selection: T
    var labelWidth: CGFloat = 80

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if !label.isEmpty {
                Text(label)
                    .font(RT.font(13, .bold))
                    .frame(width: labelWidth, alignment: .trailing)
            }
            FlowRow(spacing: 10) {
                ForEach(options.indices, id: \.self) { i in
                    let opt = options[i]
                    Button {
                        selection = opt.0
                    } label: {
                        HStack(spacing: 4) {
                            ZStack {
                                Circle().fill(Color.paper)
                                Circle().stroke(Color.ink, lineWidth: 1)
                                if selection == opt.0 {
                                    Circle().fill(Color.ink).padding(3)
                                }
                            }
                            .frame(width: 14, height: 14)
                            Text(opt.1).font(RT.font(12))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(.ink)
    }
}

/// 自动换行的横向排布。
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW {
                y += lineH + spacing
                x = 0
                lineH = 0
            }
            x += s.width + spacing
            lineH = max(lineH, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                y += lineH + spacing
                x = bounds.minX
                lineH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}

struct RetroGroup<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(.horizontal, 10)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.paper)
        .overlay(Rectangle().stroke(Color.ink, lineWidth: 1))
        .background(Rectangle().fill(Color.ink).offset(x: 2, y: 2))
        .overlay(alignment: .topLeading) {
            Text(title)
                .font(RT.font(13, .bold))
                .padding(.horizontal, 4)
                .background(Color.paper)
                .offset(x: 10, y: -9)
        }
        .padding(.top, 10)
        .foregroundColor(.ink)
    }
}

// MARK: - 等待与提示

struct RetroBusy: View {
    var text = ""
    @State private var angle = 0.0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hourglass")
                .font(.system(size: 16, weight: .bold))
                .rotationEffect(.degrees(angle))
                .onAppear {
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                        angle = 360
                    }
                }
            Text(text.isEmpty ? tr("请稍候…", "Please wait…") : text).font(RT.font(13))
        }
        .foregroundColor(.ink)
    }
}

/// 经典双线框对话框。
struct RetroDialog<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.paper.opacity(0.35).ignoresSafeArea()
            content
                .padding(18)
                .frame(maxWidth: 360)
                .background(Color.paper)
                .overlay(Rectangle().stroke(Color.ink, lineWidth: 1).padding(4))
                .overlay(Rectangle().stroke(Color.ink, lineWidth: 2))
                .background(Rectangle().fill(Color.ink).offset(x: 4, y: 4))
                .padding(24)
        }
    }
}

private struct RetroAlertModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay {
            if let m = message {
                RetroDialog {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 30, weight: .bold))
                            ScrollView {
                                Text(m)
                                    .font(RT.font(13))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 320)
                        }
                        HStack {
                            Spacer()
                            Button(tr("好", "OK")) { message = nil }
                                .buttonStyle(RetroButtonStyle(isDefault: true))
                        }
                    }
                    .foregroundColor(.ink)
                }
            }
        }
    }
}

extension View {
    func retroAlert(_ message: Binding<String?>) -> some View {
        modifier(RetroAlertModifier(message: message))
    }

    func busyOverlay(_ busy: Bool, _ text: String) -> some View {
        overlay {
            if busy {
                RetroDialog { RetroBusy(text: text) }
            }
        }
    }

    /// 底部弹出的复古面板（半屏）。
    func retroSheetStyle() -> some View {
        self
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }
}

/// 弹出面板的外框。
struct RetroPanel<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.dismiss) private var dismiss

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            StripedTitleBar(title: title, onClose: { dismiss() })
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundColor(.ink)
        .background(Color.paper.ignoresSafeArea())
    }
}

// MARK: - 菜单栏

struct RetroMenuBar<Menus: View>: View {
    let menus: Menus

    init(@ViewBuilder menus: () -> Menus) {
        self.menus = menus()
    }

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 14, weight: .bold))
            menus
            Spacer()
            TimelineView(.everyMinute) { ctx in
                Text(ctx.date, format: .dateTime.hour().minute())
            }
        }
        .font(RT.font(14, .bold))
        .foregroundColor(.ink)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.paper)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.ink).frame(height: 1) }
    }
}
