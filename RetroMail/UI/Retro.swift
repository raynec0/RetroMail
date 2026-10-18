import SwiftUI
import UIKit

// MARK: - iPhone OS 3 视觉规范
// 蓝灰渐变导航栏/工具栏、尖角返回按钮、Helvetica、白色表格、条纹分组背景、
// 蓝色未读圆点、灰色计数胶囊、深色玻璃动作表、蓝色半透明提示框。
// 夜间模式 = iPhone OS 3 的黑色栏样式（UIBarStyleBlack）+ 深色表格。

enum RT {
    static func font(_ size: CGFloat = 15, _ weight: Font.Weight = .regular) -> Font {
        let bold = weight == .bold || weight == .heavy || weight == .black || weight == .semibold
        return .custom(bold ? "Helvetica-Bold" : "Helvetica", size: size)
    }
}

private func dyn(_ light: String, _ dark: String) -> Color {
    Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
}

extension UIColor {
    convenience init(hex: String, alpha: CGFloat = 1) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt32(s, radix: 16) ?? 0
        self.init(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: alpha)
    }
}

enum IOS3 {
    // 栏
    static let barStops: [Gradient.Stop] = [
        .init(color: dyn("#B0BCCD", "#5B5B5B"), location: 0),
        .init(color: dyn("#8A9DB5", "#2E2E2E"), location: 0.5),
        .init(color: dyn("#8095AF", "#1E1E1E"), location: 0.5),
        .init(color: dyn("#6D84A2", "#040404"), location: 1),
    ]
    static let barHighlight = dyn("#CDD5DF", "#7A7A7A")
    static let barBorder = dyn("#2D3642", "#000000")
    static let barText = Color.white
    static let barTextShadow = dyn("#3A4559", "#000000")

    // 栏上的按钮
    static let buttonStops: [Gradient.Stop] = [
        .init(color: dyn("#90A5C2", "#6A6A6A"), location: 0),
        .init(color: dyn("#6E88AD", "#3A3A3A"), location: 0.5),
        .init(color: dyn("#5D789F", "#262626"), location: 0.5),
        .init(color: dyn("#4C6A92", "#121212"), location: 1),
    ]
    static let buttonBorder = dyn("#375073", "#000000")
    static let doneStops: [Gradient.Stop] = [
        .init(color: HexColor.color("#7FAEFA"), location: 0),
        .init(color: HexColor.color("#4E8BF1"), location: 0.5),
        .init(color: HexColor.color("#3A79EB"), location: 0.5),
        .init(color: HexColor.color("#2A63DD"), location: 1),
    ]
    static let doneBorder = HexColor.color("#1B3F8F")
    static let redStops: [Gradient.Stop] = [
        .init(color: HexColor.color("#F49188"), location: 0),
        .init(color: HexColor.color("#E04B3F"), location: 0.5),
        .init(color: HexColor.color("#D23426"), location: 0.5),
        .init(color: HexColor.color("#B71C10"), location: 1),
    ]
    static let redBorder = HexColor.color("#7A120A")

    // 表格
    static let separator = dyn("#E0E0E0", "#2E2E30")
    static let groupBorder = dyn("#ABABAB", "#3A3A3C")
    static let groupHeader = dyn("#4C566C", "#A9B2C2")
    static let groupHeaderShadow = dyn("#FFFFFF", "#000000")
    static let cell = dyn("#FFFFFF", "#1C1C1E")
    static let secondary = dyn("#7F7F7F", "#8E8E93")
    static let value = dyn("#385487", "#8FB0E8")
    static let dateBlue = dyn("#2470D8", "#5E9BF2")
    static let chevron = dyn("#A3A3A3", "#5A5A5E")
    static let pill = dyn("#8C99AB", "#4F5A6B")
    static let selectStops: [Gradient.Stop] = [
        .init(color: HexColor.color("#058CF5"), location: 0),
        .init(color: HexColor.color("#015EE6"), location: 1),
    ]
    static let sectionStops: [Gradient.Stop] = [
        .init(color: dyn("#A7B2BD", "#3A3D42"), location: 0),
        .init(color: dyn("#8F9CAA", "#26282C"), location: 1),
    ]
    static let searchStops: [Gradient.Stop] = [
        .init(color: dyn("#D2D9E1", "#4A4A4A"), location: 0),
        .init(color: dyn("#A9B5C3", "#1E1E1E"), location: 1),
    ]

    static var bar: LinearGradient { LinearGradient(stops: barStops, startPoint: .top, endPoint: .bottom) }
    static var barButton: LinearGradient { LinearGradient(stops: buttonStops, startPoint: .top, endPoint: .bottom) }
    static var done: LinearGradient { LinearGradient(stops: doneStops, startPoint: .top, endPoint: .bottom) }
    static var red: LinearGradient { LinearGradient(stops: redStops, startPoint: .top, endPoint: .bottom) }
    static var selection: LinearGradient { LinearGradient(stops: selectStops, startPoint: .top, endPoint: .bottom) }
}

// MARK: - 背景与线条

/// 设置页的竖条纹背景。
struct PinstripeBackground: View {
    @Environment(\.colorScheme) private var scheme

    private static func pattern(dark: Bool) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 7, height: 1), format: fmt).image { ctx in
            UIColor(hex: dark ? "#18191B" : "#CBD2D8").setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 7, height: 1))
            UIColor(hex: dark ? "#1F2023" : "#C5CCD4").setFill()
            ctx.fill(CGRect(x: 4, y: 0, width: 3, height: 1))
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

/// 兼容旧代码：网点背景现在也画成条纹。
struct DitherBackground: View {
    var body: some View { PinstripeBackground() }
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
        Rectangle().fill(IOS3.separator).frame(height: 1)
    }
}

struct GlossFill: View {
    var body: some View {
        LinearGradient(colors: [.white, HexColor.color("#E6E6E6")], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - 导航栏

/// 尖角返回按钮的形状。
struct BackArrowShape: Shape {
    func path(in r: CGRect) -> Path {
        let rad: CGFloat = 5
        let tip: CGFloat = min(12, r.height * 0.4)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + tip, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - rad, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + rad), radius: rad)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rad))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - rad, y: r.maxY), radius: rad)
        p.addLine(to: CGPoint(x: r.minX + tip, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + tip, y: r.minY), control: CGPoint(x: r.minX - 2, y: r.midY))
        p.closeSubpath()
        return p
    }
}

enum BarButtonKind {
    case plain, done, red, back
}

/// 栏上的按钮（有边框的蓝灰按钮、蓝色“完成”按钮、红色按钮、返回按钮）。
struct BarButtonStyle: ButtonStyle {
    var kind: BarButtonKind = .plain

    func makeBody(configuration: Configuration) -> some View {
        BarButtonBody(configuration: configuration, kind: kind)
    }
}

private struct BarButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: BarButtonKind
    @Environment(\.isEnabled) private var enabled

    private var fill: LinearGradient {
        switch kind {
        case .done: return IOS3.done
        case .red: return IOS3.red
        default: return IOS3.barButton
        }
    }

    private var border: Color {
        switch kind {
        case .done: return IOS3.doneBorder
        case .red: return IOS3.redBorder
        default: return IOS3.buttonBorder
        }
    }

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(RT.font(12, .bold))
            .lineLimit(1)
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.45), radius: 0, x: 0, y: -1)
            .padding(.leading, kind == .back ? 15 : 9)
            .padding(.trailing, 9)
            .frame(minWidth: kind == .back ? 50 : 34, minHeight: 30)
            .background {
                if kind == .back {
                    ZStack {
                        BackArrowShape().fill(fill)
                        BackArrowShape().fill(Color.black.opacity(pressed ? 0.3 : 0))
                        BackArrowShape().stroke(border, lineWidth: 1)
                    }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5).fill(fill)
                        RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(pressed ? 0.3 : 0))
                        RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.22), lineWidth: 1).padding(1)
                        RoundedRectangle(cornerRadius: 5).stroke(border, lineWidth: 1)
                    }
                }
            }
            .shadow(color: .white.opacity(0.25), radius: 0, x: 0, y: 1)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

struct IOS3NavBar<Leading: View, Trailing: View>: View {
    let title: String
    let leading: Leading
    let trailing: Trailing

    init(title: String, @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                leading
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 6)
            Text(title)
                .font(RT.font(19, .bold))
                .foregroundColor(IOS3.barText)
                .shadow(color: IOS3.barTextShadow, radius: 0, x: 0, y: -1)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 84)
                .allowsHitTesting(false)
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(IOS3.bar.ignoresSafeArea(edges: .top))
        .overlay(alignment: .top) { Rectangle().fill(IOS3.barHighlight).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(IOS3.barBorder).frame(height: 1) }
    }
}

/// 兼容旧代码：标题栏 = iOS 3 导航栏，onClose 显示为右侧“完成”。
struct StripedTitleBar: View {
    let title: String
    var onClose: (() -> Void)?

    var body: some View {
        IOS3NavBar(title: title) {
            EmptyView()
        } trailing: {
            if let onClose = onClose {
                Button(tr("完成", "Done"), action: onClose)
                    .buttonStyle(BarButtonStyle(kind: .done))
            }
        }
    }
}

/// 推入导航栈的页面：顶部导航栏（尖角返回按钮 + 标题 + 右侧按钮）。
struct RetroScreen<Trailing: View, Content: View>: View {
    let title: String
    var back: String?
    var showClose: Bool
    var background: Color?
    let trailing: Trailing
    let content: Content
    @Environment(\.dismiss) private var dismiss

    init(title: String, back: String? = nil, showClose: Bool = true, background: Color? = nil,
         @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title
        self.back = back
        self.showClose = showClose
        self.background = background
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            IOS3NavBar(title: title) {
                if showClose {
                    Button(back ?? tr("返回", "Back")) { dismiss() }
                        .buttonStyle(BarButtonStyle(kind: .back))
                }
            } trailing: {
                trailing
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundColor(.ink)
        .background {
            if let bg = background {
                bg.ignoresSafeArea()
            } else {
                PinstripeBackground()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

extension RetroScreen where Trailing == EmptyView {
    init(title: String, back: String? = nil, showClose: Bool = true, background: Color? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, back: back, showClose: showClose, background: background,
                  trailing: { EmptyView() }, content: content)
    }
}

// MARK: - 底部工具栏

struct IOS3Toolbar<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 6)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(IOS3.bar.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle().fill(IOS3.barBorder).frame(height: 1)
                Rectangle().fill(IOS3.barHighlight.opacity(0.7)).frame(height: 1)
            }
        }
    }
}

/// 工具栏上的白色图标按钮（无边框，按下时发光）。
struct ToolbarIcon: View {
    let symbol: String
    var label: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarIconStyle())
        .accessibilityLabel(label ?? symbol)
    }
}

private struct ToolbarIconStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.5), radius: 0, x: 0, y: -1)
            .shadow(color: .white.opacity(configuration.isPressed ? 0.9 : 0), radius: 6)
            .opacity(enabled ? 1 : 0.4)
    }
}

/// 工具栏中间的状态文字（如“已更新 13:01”）。
struct ToolbarStatus: View {
    let text: String

    var body: some View {
        Text(text)
            .font(RT.font(11, .bold))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.45), radius: 0, x: 0, y: -1)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - 搜索栏

struct IOS3SearchBar: View {
    @Binding var text: String
    var placeholder: String
    var busy = false
    var onSubmit: () -> Void
    var onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .bold)).foregroundColor(IOS3.secondary)
                TextField(placeholder, text: $text)
                    .font(RT.font(15))
                    .foregroundColor(.black)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .onSubmit(onSubmit)
                if busy {
                    ProgressView().scaleEffect(0.7)
                } else if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(HexColor.color("#9A9A9A"))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().stroke(HexColor.color("#7F8A97"), lineWidth: 1))
            .overlay(Capsule().stroke(Color.black.opacity(0.15), lineWidth: 2).blur(radius: 1).clipShape(Capsule()))
            if focused || !text.isEmpty {
                Button(tr("取消", "Cancel")) {
                    focused = false
                    onCancel()
                }
                .buttonStyle(BarButtonStyle())
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 44)
        .background(LinearGradient(stops: IOS3.searchStops, startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .bottom) { Rectangle().fill(HexColor.color("#8E99A6")).frame(height: 1) }
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

// MARK: - 表格元素

/// 行被按下时的蓝色高亮：内容通过环境值 rowPressed 改成白色。
private struct RowPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var rowPressed: Bool {
        get { self[RowPressedKey.self] }
        set { self[RowPressedKey.self] = newValue }
    }
}

struct InvertOnPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(configuration.isPressed ? .white : .ink)
            .environment(\.rowPressed, configuration.isPressed)
            .background {
                if configuration.isPressed {
                    IOS3.selection
                } else {
                    IOS3.cell
                }
            }
    }
}

struct Chevron: View {
    @Environment(\.rowPressed) private var pressed

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(pressed ? .white : IOS3.chevron)
    }
}

/// 灰色未读计数胶囊。
struct CountPill: View {
    let count: Int
    @Environment(\.rowPressed) private var pressed

    var body: some View {
        Text(count > 9999 ? "9999+" : "\(count)")
            .font(RT.font(15, .bold))
            .foregroundColor(pressed ? IOS3.dateBlue : .white)
            .padding(.horizontal, 8)
            .frame(minWidth: 30, minHeight: 22)
            .background(Capsule().fill(pressed ? Color.white : IOS3.pill))
    }
}

/// 蓝色玻璃未读圆点。
struct UnreadDot: View {
    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [HexColor.color("#8CC4FF"), HexColor.color("#1A64DA")], startPoint: .top, endPoint: .bottom))
            .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0)], startPoint: .top, endPoint: .center)).padding(1.5))
            .overlay(Circle().stroke(HexColor.color("#1450B0"), lineWidth: 0.5))
            .frame(width: 12, height: 12)
    }
}

/// 普通表格的分组标题条（灰蓝渐变 + 白字）。
struct PlainSectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title).lineLimit(1)
            Spacer()
            if let t = trailing { Text(t).lineLimit(1) }
        }
        .font(RT.font(16, .bold))
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: 1)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(stops: IOS3.sectionStops, startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Color.black.opacity(0.18)).frame(height: 1) }
    }
}

// MARK: - 按钮：白色圆角玻璃按钮

struct RetroButtonStyle: ButtonStyle {
    var isDefault = false
    var compact = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        RoundRectButtonBody(configuration: configuration, isDefault: isDefault, compact: compact, destructive: destructive)
    }
}

private struct RoundRectButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isDefault: Bool
    let compact: Bool
    let destructive: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let pressed = configuration.isPressed
        let filled = pressed || isDefault || destructive
        let radius: CGFloat = compact ? 6 : 8
        configuration.label
            .font(RT.font(compact ? 13 : 16, .bold))
            .lineLimit(1)
            .padding(.horizontal, compact ? 11 : 18)
            .padding(.vertical, compact ? 6 : 10)
            .foregroundColor(filled ? .white : IOS3.value)
            .shadow(color: .black.opacity(filled ? 0.35 : 0), radius: 0, x: 0, y: -1)
            .background {
                ZStack {
                    if destructive {
                        RoundedRectangle(cornerRadius: radius).fill(IOS3.red)
                    } else if filled {
                        RoundedRectangle(cornerRadius: radius).fill(IOS3.done)
                    } else {
                        RoundedRectangle(cornerRadius: radius).fill(
                            LinearGradient(colors: [IOS3.cell, dyn("#E9E9E9", "#2C2C2E")], startPoint: .top, endPoint: .bottom))
                    }
                    if pressed && (isDefault || destructive) {
                        RoundedRectangle(cornerRadius: radius).fill(Color.black.opacity(0.25))
                    }
                    RoundedRectangle(cornerRadius: radius)
                        .stroke(destructive ? IOS3.redBorder : filled ? IOS3.doneBorder : IOS3.groupBorder, lineWidth: 1)
                }
            }
            .shadow(color: .white.opacity(0.6), radius: 0, x: 0, y: 1)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

// MARK: - 方块按钮（写信格式栏 / 面板里的选项）：iOS 3 栏按钮样式

struct TileStyle: ButtonStyle {
    var active = false
    var depth: CGFloat = 2

    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration, active: active)
    }
}

private struct TileBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let on = configuration.isPressed || active
        configuration.label
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.45), radius: 0, x: 0, y: -1)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(on ? IOS3.done : IOS3.barButton)
                    if configuration.isPressed {
                        RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.2))
                    }
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.22), lineWidth: 1).padding(1)
                    RoundedRectangle(cornerRadius: 6).stroke(on ? IOS3.doneBorder : IOS3.buttonBorder, lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)
            .opacity(enabled ? 1 : 0.35)
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
                        Image(systemName: s).font(.system(size: size * 0.34, weight: .semibold))
                    } else {
                        Text(glyph ?? "").font(glyphFont ?? .system(size: size * 0.36, weight: .bold, design: .serif))
                    }
                }
                .frame(height: size * 0.46)
                Text(label)
                    .font(RT.font(9.5, .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 2)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(TileStyle(active: active))
    }
}

// MARK: - 开关与分段控件

/// iPhone OS 3 的蓝色 ON / OFF 开关。
struct IOS3Switch: View {
    @Binding var isOn: Bool

    var body: some View {
        let w: CGFloat = 94, h: CGFloat = 27, knob: CGFloat = 40
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isOn
                          ? LinearGradient(colors: [HexColor.color("#2D6BDA"), HexColor.color("#5D9DF5")], startPoint: .top, endPoint: .bottom)
                          : LinearGradient(colors: [HexColor.color("#E4E4E4"), HexColor.color("#FDFDFD")], startPoint: .top, endPoint: .bottom))
                HStack {
                    if isOn {
                        Text(tr("开", "ON")).font(RT.font(16, .bold)).foregroundColor(.white)
                            .shadow(color: .black.opacity(0.35), radius: 0, x: 0, y: -1)
                            .frame(width: w - knob)
                        Spacer(minLength: 0)
                    } else {
                        Spacer(minLength: 0)
                        Text(tr("关", "OFF")).font(RT.font(16, .bold)).foregroundColor(HexColor.color("#808080"))
                            .frame(width: w - knob)
                    }
                }
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [HexColor.color("#FFFFFF"), HexColor.color("#D9D9D9")], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(HexColor.color("#9A9A9A"), lineWidth: 1))
                    .frame(width: knob, height: h)
                    .shadow(color: .black.opacity(0.25), radius: 1, x: isOn ? -1 : 1, y: 0)
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(HexColor.color("#8A8A8A"), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "ON" : "OFF")
    }
}

/// iPhone OS 3 分段控件（白灰底，选中蓝色）。
struct IOS3Segmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let opt = options[i]
                let on = selection == opt.0
                Button {
                    selection = opt.0
                } label: {
                    Text(opt.1)
                        .font(RT.font(13, .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundColor(on ? .white : HexColor.color("#5C5C5C"))
                        .shadow(color: on ? .black.opacity(0.35) : .white.opacity(0.8), radius: 0, x: 0, y: on ? -1 : 1)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(on ? AnyView(IOS3.done) : AnyView(LinearGradient(colors: [HexColor.color("#FFFFFF"), HexColor.color("#DCDCDC")], startPoint: .top, endPoint: .bottom)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < options.count - 1 {
                    Rectangle().fill(HexColor.color("#8D8D8D")).frame(width: 1)
                }
            }
        }
        .frame(height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(HexColor.color("#8D8D8D"), lineWidth: 1))
    }
}

// MARK: - 表单控件（放在 RetroGroup 分组里时显示为表格行）

struct RetroField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var secure = false
    var keyboard: UIKeyboardType = .default
    var labelWidth: CGFloat = 92

    var body: some View {
        HStack(spacing: 8) {
            if !label.isEmpty {
                Text(label)
                    .font(RT.font(15, .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: labelWidth, alignment: .leading)
            }
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(RT.font(15))
            .foregroundColor(IOS3.value)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
        }
        .frame(minHeight: 28)
        .foregroundColor(.ink)
    }
}

struct RetroCheckbox: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(RT.font(15, .bold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            IOS3Switch(isOn: $isOn)
        }
        .foregroundColor(.ink)
    }
}

/// 单选：标签 + 分段控件。
struct RetroRadio<T: Hashable>: View {
    let label: String
    let options: [(T, String)]
    @Binding var selection: T
    var labelWidth: CGFloat = 92

    var body: some View {
        Group {
            if options.count > 3 || label.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !label.isEmpty { Text(label).font(RT.font(15, .bold)) }
                    IOS3Segmented(options: options, selection: $selection)
                }
            } else {
                HStack(spacing: 8) {
                    Text(label)
                        .font(RT.font(15, .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: labelWidth, alignment: .leading)
                    IOS3Segmented(options: options, selection: $selection)
                }
            }
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

/// 子视图之间自动插入分隔线。
struct DividedStack<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        _VariadicView.Tree(DividedLayout()) { content }
    }

    private struct DividedLayout: _VariadicView_MultiViewRoot {
        @ViewBuilder
        func body(children: _VariadicView.Children) -> some View {
            let last = children.last?.id
            VStack(alignment: .leading, spacing: 0) {
                ForEach(children) { child in
                    child
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    if child.id != last {
                        Rectangle().fill(IOS3.groupBorder).frame(height: 1)
                    }
                }
            }
        }
    }
}

/// iPhone OS 3 分组表格：条纹背景上的白色圆角块，标题在块上方。
struct RetroGroup<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(RT.font(16, .bold))
                    .foregroundColor(IOS3.groupHeader)
                    .shadow(color: IOS3.groupHeaderShadow, radius: 0, x: 0, y: 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
            }
            DividedStack { content }
                .background(RoundedRectangle(cornerRadius: 10).fill(IOS3.cell))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(IOS3.groupBorder, lineWidth: 1))
                .shadow(color: .white.opacity(0.5), radius: 0, x: 0, y: 1)
        }
        .padding(.top, 10)
        .foregroundColor(.ink)
    }
}

/// 分组块（带标题），用于欢迎页、错误提示等。
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
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(RT.font(16, .bold))
                .foregroundColor(IOS3.groupHeader)
                .shadow(color: IOS3.groupHeaderShadow, radius: 0, x: 0, y: 1)
                .padding(.horizontal, 10)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(IOS3.cell))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(IOS3.groupBorder, lineWidth: 1))
        }
    }
}

// MARK: - 等待

struct RetroBusy: View {
    var text = ""
    var light = false

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(light ? .white : IOS3.secondary)
            Text(text.isEmpty ? tr("正在载入…", "Loading…") : text)
                .font(RT.font(15, .bold))
                .foregroundColor(light ? .white : IOS3.secondary)
        }
    }
}

// MARK: - 提示框（蓝色半透明 UIAlertView）

struct IOS3AlertButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RT.font(17, .bold))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.5), radius: 0, x: 0, y: -1)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(colors: [Color.white.opacity(primary ? 0.45 : 0.35), Color.white.opacity(primary ? 0.18 : 0.08)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(configuration.isPressed ? 0.3 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.black.opacity(0.5), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

struct RetroDialog<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            content
                .foregroundColor(.white)
                .padding(16)
                .frame(maxWidth: 290)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(colors: [HexColor.color("#25407A").opacity(0.94), HexColor.color("#0E1F47").opacity(0.94)],
                                             startPoint: .top, endPoint: .bottom))
                )
                .overlay(
                    Ellipse()
                        .fill(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                        .frame(height: 70)
                        .offset(y: -28)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .allowsHitTesting(false),
                    alignment: .top
                )
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.9), lineWidth: 2))
                .shadow(color: .black.opacity(0.6), radius: 10, x: 0, y: 4)
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
                    VStack(spacing: 14) {
                        ScrollView {
                            Text(m)
                                .font(RT.font(15))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .shadow(color: .black.opacity(0.5), radius: 0, x: 0, y: -1)
                        }
                        .frame(maxHeight: 300)
                        .fixedSize(horizontal: false, vertical: true)
                        Button(tr("好", "OK")) { message = nil }
                            .buttonStyle(IOS3AlertButtonStyle(primary: true))
                    }
                }
            }
        }
    }
}

/// 黑色半透明“正在…”提示（HUD）。
private struct HUDModifier: ViewModifier {
    let busy: Bool
    let text: String

    func body(content: Content) -> some View {
        content.overlay {
            if busy {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().tint(.white).scaleEffect(1.5)
                        Text(text).font(RT.font(15, .bold)).foregroundColor(.white).multilineTextAlignment(.center)
                    }
                    .padding(22)
                    .frame(minWidth: 150, minHeight: 120)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.75)))
                }
            }
        }
    }
}

// MARK: - 动作表（底部深色玻璃面板 + 大按钮）

struct SheetAction: Identifiable {
    enum Role { case normal, destructive }

    let id = UUID()
    let title: String
    var role: Role = .normal
    let action: () -> Void

    init(_ title: String, role: Role = .normal, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }
}

private struct ActionSheetButtonStyle: ButtonStyle {
    enum Kind { case normal, destructive, cancel }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        let fill: AnyView
        switch kind {
        case .normal:
            fill = AnyView(LinearGradient(colors: [HexColor.color("#FFFFFF"), HexColor.color("#DCDCDC")], startPoint: .top, endPoint: .bottom))
        case .destructive:
            fill = AnyView(IOS3.red)
        case .cancel:
            fill = AnyView(LinearGradient(stops: [.init(color: HexColor.color("#6A7686"), location: 0),
                                                  .init(color: HexColor.color("#46525F"), location: 0.5),
                                                  .init(color: HexColor.color("#3A4553"), location: 0.5),
                                                  .init(color: HexColor.color("#2C3642"), location: 1)],
                                          startPoint: .top, endPoint: .bottom))
        }
        return configuration.label
            .font(RT.font(19, .bold))
            .foregroundColor(kind == .normal ? .black : .white)
            .shadow(color: kind == .normal ? .white : .black.opacity(0.5), radius: 0, x: 0, y: kind == .normal ? 1 : -1)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(fill.clipShape(RoundedRectangle(cornerRadius: 9)))
            .overlay(RoundedRectangle(cornerRadius: 9).fill(configuration.isPressed ? AnyShapeStyle(IOS3.selection) : AnyShapeStyle(Color.clear)).opacity(0.85))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.black.opacity(0.6), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

private struct ActionSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let title: String?
    let actions: [SheetAction]

    func body(content: Content) -> some View {
        content.overlay {
            ZStack(alignment: .bottom) {
                if isPresented {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { isPresented = false }
                        .transition(.opacity)
                    VStack(spacing: 10) {
                        if let t = title, !t.isEmpty {
                            Text(t)
                                .font(RT.font(14))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .shadow(color: .black.opacity(0.6), radius: 0, x: 0, y: -1)
                                .padding(.horizontal, 6)
                                .padding(.bottom, 2)
                        }
                        ForEach(actions) { a in
                            Button(a.title) {
                                isPresented = false
                                a.action()
                            }
                            .buttonStyle(ActionSheetButtonStyle(kind: a.role == .destructive ? .destructive : .normal))
                        }
                        Button(tr("取消", "Cancel")) { isPresented = false }
                            .buttonStyle(ActionSheetButtonStyle(kind: .cancel))
                            .padding(.top, 6)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 14)
                    .frame(maxWidth: 520)
                    .background(
                        LinearGradient(colors: [HexColor.color("#3C4A5E").opacity(0.94), HexColor.color("#151C26").opacity(0.96)],
                                       startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea(edges: .bottom)
                    )
                    .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.35)).frame(height: 1) }
                    .transition(.move(edge: .bottom))
                }
            }
            .animation(.easeOut(duration: 0.22), value: isPresented)
        }
    }
}

extension View {
    func retroAlert(_ message: Binding<String?>) -> some View {
        modifier(RetroAlertModifier(message: message))
    }

    func busyOverlay(_ busy: Bool, _ text: String) -> some View {
        modifier(HUDModifier(busy: busy, text: text))
    }

    /// iPhone OS 3 风格的动作表。“取消”按钮自动加在最后。
    func ios3ActionSheet(isPresented: Binding<Bool>, title: String? = nil, actions: [SheetAction]) -> some View {
        modifier(ActionSheetModifier(isPresented: isPresented, title: title, actions: actions))
    }

    /// 底部弹出的面板（半屏/全屏）。
    func retroSheetStyle() -> some View {
        self
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
    }
}

/// 弹出面板：iOS 3 模态页（导航栏 + “完成”按钮，条纹背景）。
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
        .background(PinstripeBackground())
    }
}

// MARK: - 旧版菜单栏（保留以兼容）

struct RetroMenuBar<Menus: View>: View {
    let menus: Menus

    init(@ViewBuilder menus: () -> Menus) {
        self.menus = menus()
    }

    var body: some View {
        HStack(spacing: 20) {
            menus
            Spacer()
        }
        .font(RT.font(14, .bold))
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}
