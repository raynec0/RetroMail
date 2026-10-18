import SwiftUI
import UIKit

// MARK: - 古早 iOS 桌面图标：彩色渐变 + 上半部高光 + 黑色描边 + 投影，文字在图标下方

struct IconColors {
    let top: Color
    let bottom: Color

    init(_ top: String, _ bottom: String) {
        self.top = HexColor.color(top)
        self.bottom = HexColor.color(bottom)
    }

    static let blue = IconColors("#6CC0FF", "#1559D1")
    static let orange = IconColors("#FFC066", "#E5630E")
    static let green = IconColors("#8BE36A", "#24921C")
    static let yellow = IconColors("#FFE46B", "#D99A00")
    static let gray = IconColors("#C9CED6", "#5F6874")
    static let brown = IconColors("#E2B27A", "#83521F")
    static let purple = IconColors("#C99BFF", "#6E33C9")
    static let teal = IconColors("#6FE8D9", "#108F84")
    static let pink = IconColors("#FF9CC4", "#D02A6E")
    static let indigo = IconColors("#9BAAFF", "#3141BD")
    static let red = IconColors("#FF8A7A", "#C21E12")
    static let graphite = IconColors("#8E959E", "#2F343A")

    private static let others: [IconColors] = [.purple, .teal, .pink, .indigo, .red, .brown, .blue, .green]

    /// 自定义文件夹按名字固定分配一种颜色。
    static func stable(for name: String) -> IconColors {
        var h: UInt32 = 2166136261
        for b in name.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return others[Int(h % UInt32(others.count))]
    }
}

extension FolderRole {
    var springSymbol: String {
        switch self {
        case .inbox: return "tray.fill"
        case .drafts: return "doc.text.fill"
        case .sent: return "paperplane.fill"
        case .junk: return "xmark.bin.fill"
        case .trash: return "trash.fill"
        case .archive: return "archivebox.fill"
        case .other: return "folder.fill"
        }
    }
}

extension MailFolder {
    var iconColors: IconColors {
        switch role {
        case .inbox: return .blue
        case .drafts: return .orange
        case .sent: return .green
        case .junk: return .yellow
        case .trash: return .gray
        case .archive: return .brown
        case .other: return .stable(for: path)
        }
    }
}

/// 图标上半部的弧形高光。
private struct GlossShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.42))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.42),
                       control: CGPoint(x: r.midX, y: r.minY + r.height * 0.60))
        p.closeSubpath()
        return p
    }
}

struct GlossyIcon: View {
    let symbol: String
    let colors: IconColors
    var size: CGFloat = 60
    var badge: Int = 0
    var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [colors.top, colors.bottom], startPoint: .top, endPoint: .bottom))
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.45), radius: 0, x: 0, y: -1)
                .shadow(color: .black.opacity(0.25), radius: 1.5, x: 0, y: 1)
            GlossShape()
                .fill(LinearGradient(colors: [.white.opacity(0.62), .white.opacity(0.14)], startPoint: .top, endPoint: .bottom))
                .clipShape(shape)
            shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 1).padding(1)
            shape.strokeBorder(Color.black.opacity(0.55), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .brightness(pressed ? -0.28 : 0)
        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 2.5)
        .overlay(alignment: .topTrailing) {
            if badge > 0 {
                UnreadBadge(count: badge)
                    .offset(x: size * 0.16, y: -size * 0.16)
            }
        }
    }
}

/// 经典 iOS 红色未读角标。
struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count > 999 ? "999+" : "\(count)")
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 25, minHeight: 25)
            .background(
                Capsule().fill(LinearGradient(colors: [HexColor.color("#FF6E6E"), HexColor.color("#C8100A")],
                                              startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                Capsule().fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0)],
                                              startPoint: .top, endPoint: .center))
                    .padding(2)
            )
            .overlay(Capsule().stroke(Color.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.5), radius: 1.5, x: 0, y: 1.5)
    }
}

/// 图标 + 下方文字的按钮。plate = 文字带底板（放在花纹桌面上时更清楚）。
struct SpringButton: View {
    let symbol: String
    let label: String
    var colors: IconColors = .blue
    var size: CGFloat = 60
    var badge: Int = 0
    var plate = false
    var labelWidth: CGFloat?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            EmptyView()
        }
        .buttonStyle(SpringStyle(symbol: symbol, label: label, colors: colors, size: size,
                                 badge: badge, plate: plate, labelWidth: labelWidth))
    }
}

private struct SpringStyle: ButtonStyle {
    let symbol: String
    let label: String
    let colors: IconColors
    let size: CGFloat
    let badge: Int
    let plate: Bool
    let labelWidth: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        SpringBody(pressed: configuration.isPressed, symbol: symbol, label: label, colors: colors,
                   size: size, badge: badge, plate: plate, labelWidth: labelWidth)
    }
}

private struct SpringBody: View {
    let pressed: Bool
    let symbol: String
    let label: String
    let colors: IconColors
    let size: CGFloat
    let badge: Int
    let plate: Bool
    let labelWidth: CGFloat?
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        VStack(spacing: size > 50 ? 6 : 4) {
            GlossyIcon(symbol: symbol, colors: colors, size: size, badge: badge, pressed: pressed)
                .scaleEffect(pressed ? 0.94 : 1)
            Text(label)
                .font(.system(size: size > 50 ? 12 : 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundColor(.ink)
                .padding(.horizontal, plate ? 4 : 0)
                .padding(.vertical, plate ? 1 : 0)
                .background {
                    if plate {
                        Rectangle().fill(Color.paper)
                    }
                }
                .frame(maxWidth: labelWidth ?? (size + 22))
        }
        .opacity(enabled ? 1 : 0.4)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

// MARK: - Dock：底部玻璃架子

struct SpringDock<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            content
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: 520)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color.paper.opacity(0.92), Color.mist.opacity(0.92), Color.shade.opacity(0.95)],
                                     startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0)], startPoint: .top, endPoint: .center))
                .padding(1.5)
                .allowsHitTesting(false)
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.ink, lineWidth: 1.5))
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.ink).offset(x: 3, y: 3)
        )
    }
}

/// 桌面背景：稀疏网点（25%），比 50% 网点更安静，彩色图标更突出。
struct SpringWallpaper: View {
    @Environment(\.colorScheme) private var scheme

    private static func pattern(dark: Bool) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: fmt).image { ctx in
            (dark ? UIColor(white: 0.10, alpha: 1) : UIColor(white: 0.93, alpha: 1)).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            (dark ? UIColor(white: 0.26, alpha: 1) : UIColor(white: 0.62, alpha: 1)).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
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
