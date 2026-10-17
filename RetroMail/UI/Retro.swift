import SwiftUI
import UIKit

/// 经典 Mac OS（System 6/7）风格的黑白组件。
enum RT {
    static func font(_ size: CGFloat = 15, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - 背景与线条

struct DitherBackground: View {
    static let pattern: UIImage = {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: fmt).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            ctx.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
        }
    }()

    var body: some View {
        Rectangle()
            .fill(ImagePaint(image: Image(uiImage: Self.pattern), scale: 1))
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
            HLine().stroke(Color.black, style: StrokeStyle(lineWidth: 1, dash: [1, 2])).frame(height: 1)
        } else {
            Rectangle().fill(Color.black).frame(height: 1)
        }
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
                    Rectangle().fill(Color.black).frame(height: 1)
                }
            }
            .padding(.horizontal, 3)

            HStack(spacing: 0) {
                if let onClose = onClose {
                    Button(action: onClose) {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 13, height: 13)
                            .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                            .padding(.horizontal, 3)
                            .background(Color.white)
                            .frame(width: 44, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }
                Spacer()
            }

            Text(title)
                .font(RT.font(14, .bold))
                .foregroundColor(.black)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .background(Color.white)
                .padding(.horizontal, 48)
        }
        .frame(height: 24)
        .background(Color.white)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black).frame(height: 1) }
    }
}

struct RetroWindow<Content: View>: View {
    let title: String
    var onClose: (() -> Void)?
    var fill: Bool
    let content: Content

    init(title: String, onClose: (() -> Void)? = nil, fill: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.onClose = onClose
        self.fill = fill
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            StripedTitleBar(title: title, onClose: onClose)
            if fill {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Color.white)
            } else {
                content
                    .frame(maxWidth: .infinity, alignment: .top)
                    .background(Color.white)
            }
        }
        .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
        .background(Rectangle().fill(Color.black).offset(x: 2, y: 2))
    }
}

/// 推入导航栈的整屏窗口：关闭框 = 返回。
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
        ZStack {
            DitherBackground()
            RetroWindow(title: title, onClose: showClose ? { dismiss() } : nil) {
                content
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - 按钮

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
        configuration.label
            .font(RT.font(compact ? 13 : 15, .bold))
            .lineLimit(1)
            .padding(.horizontal, compact ? 9 : 14)
            .padding(.vertical, compact ? 5 : 7)
            .foregroundColor(pressed ? .white : .black)
            .background(RoundedRectangle(cornerRadius: 7).fill(pressed ? Color.black : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.black, lineWidth: 1.5))
            .padding(isDefault ? 3 : 0)
            .overlay {
                if isDefault {
                    RoundedRectangle(cornerRadius: 10).stroke(Color.black, lineWidth: 3)
                }
            }
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }
}

/// 列表行：按下时黑白反转。
struct InvertOnPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(configuration.isPressed ? .white : .black)
            .background(configuration.isPressed ? Color.black : Color.white)
    }
}

struct ToolIcon: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                Text(label).font(RT.font(10))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(InvertOnPressStyle())
    }
}

struct DesktopIcon: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .regular))
                    .frame(width: 48, height: 44)
                    .background(Color.white)
                    .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
                Text(label)
                    .font(RT.font(11, .bold))
                    .padding(.horizontal, 3)
                    .background(Color.white)
            }
            .foregroundColor(.black)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 表单控件

struct RetroField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var secure = false
    var keyboard: UIKeyboardType = .default
    var labelWidth: CGFloat = 76

    var body: some View {
        HStack(spacing: 6) {
            if !label.isEmpty {
                Text(label)
                    .font(RT.font(13, .bold))
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
            .background(Color.white)
            .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
        }
        .foregroundColor(.black)
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
                    Rectangle().fill(Color.white)
                    Rectangle().stroke(Color.black, lineWidth: 1)
                    if isOn {
                        Path { p in
                            p.move(to: CGPoint(x: 2, y: 2))
                            p.addLine(to: CGPoint(x: 12, y: 12))
                            p.move(to: CGPoint(x: 12, y: 2))
                            p.addLine(to: CGPoint(x: 2, y: 12))
                        }
                        .stroke(Color.black, lineWidth: 1.5)
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
            .foregroundColor(.black)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct RetroRadioRow: View {
    let label: String
    @Binding var selection: MailSecurity
    var labelWidth: CGFloat = 76

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(RT.font(13, .bold))
                .frame(width: labelWidth, alignment: .trailing)
            ForEach(MailSecurity.allCases) { s in
                Button {
                    selection = s
                } label: {
                    HStack(spacing: 3) {
                        ZStack {
                            Circle().fill(Color.white)
                            Circle().stroke(Color.black, lineWidth: 1)
                            if selection == s {
                                Circle().fill(Color.black).padding(3)
                            }
                        }
                        .frame(width: 13, height: 13)
                        Text(s.label).font(RT.font(11))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .foregroundColor(.black)
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
        .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            Text(title)
                .font(RT.font(13, .bold))
                .padding(.horizontal, 4)
                .background(Color.white)
                .offset(x: 10, y: -9)
        }
        .padding(.top, 8)
        .foregroundColor(.black)
    }
}

// MARK: - 等待与提示

struct RetroBusy: View {
    var text = "请稍候…"
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
            Text(text).font(RT.font(13))
        }
        .foregroundColor(.black)
    }
}

/// 经典的双线框对话框。
struct RetroDialog<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.white.opacity(0.01).ignoresSafeArea()
            content
                .padding(18)
                .frame(maxWidth: 340)
                .background(Color.white)
                .overlay(Rectangle().stroke(Color.black, lineWidth: 1).padding(4))
                .overlay(Rectangle().stroke(Color.black, lineWidth: 2))
                .background(Rectangle().fill(Color.black).offset(x: 3, y: 3))
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
                            Text(m)
                                .font(RT.font(13))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        HStack {
                            Spacer()
                            Button("好") { message = nil }
                                .buttonStyle(RetroButtonStyle(isDefault: true))
                        }
                    }
                    .foregroundColor(.black)
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
        .foregroundColor(.black)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.white)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black).frame(height: 1) }
    }
}
