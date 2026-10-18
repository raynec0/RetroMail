import SwiftUI

enum RibbonTab: String, CaseIterable, Identifiable {
    case home, paragraph, insert, table, tools
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return tr("开始", "Home")
        case .paragraph: return tr("段落", "Paragraph")
        case .insert: return tr("插入", "Insert")
        case .table: return tr("表格", "Table")
        case .tools: return tr("工具", "Tools")
        }
    }
}

enum EditorSheet: String, Identifiable {
    case font, size, color, highlight, cellFill, bullets, numbering, spacing, styles, link, table, symbols, find, ai
    var id: String { rawValue }
}

/// Outlook 式功能区：分组标签 + 方块按钮。
struct FormatRibbon: View {
    @ObservedObject var ed: EditorController
    @Binding var sheet: EditorSheet?
    @Binding var priority: MailPriority
    @Binding var readReceipt: Bool
    var onInlineImage: () -> Void
    var onAttachPhoto: () -> Void
    var onAttachFile: () -> Void
    var onSignature: () -> Void
    var onSaveDraft: () -> Void
    var onSend: () -> Void
    /// 动作表交给写信页显示（覆盖整个屏幕）
    var onActionSheet: (String, [SheetAction]) -> Void = { _, _ in }

    @State private var tab: RibbonTab = .home
    @State private var painterHint: String?

    private let size: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tiles
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 9)
            }
            .background(IOS3.bar)
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    Rectangle().fill(IOS3.barBorder).frame(height: 1)
                    Rectangle().fill(IOS3.barHighlight.opacity(0.7)).frame(height: 1)
                }
            }
            IOS3Segmented(options: RibbonTab.allCases.map { ($0, $0.title) }, selection: $tab)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(LinearGradient(stops: IOS3.searchStops, startPoint: .top, endPoint: .bottom))
        }
        .foregroundColor(.ink)
    }

    private var caseActions: [SheetAction] {
        [
            SheetAction(tr("全部大写 ABC", "UPPERCASE")) { ed.call("changeCase", "upper") },
            SheetAction(tr("全部小写 abc", "lowercase")) { ed.call("changeCase", "lower") },
            SheetAction(tr("首字母大写 Abc", "Capitalize Each Word")) { ed.call("changeCase", "title") },
        ]
    }

    private var priorityActions: [SheetAction] {
        MailPriority.allCases.map { p in SheetAction(p.label) { priority = p } }
    }

    private var attachActions: [SheetAction] {
        [
            SheetAction(tr("照片或视频", "Photo or Video")) { onAttachPhoto() },
            SheetAction(tr("文件", "File")) { onAttachFile() },
        ]
    }

    @ViewBuilder
    private var tiles: some View {
        switch tab {
        case .home: homeTiles
        case .paragraph: paragraphTiles
        case .insert: insertTiles
        case .table: tableTiles
        case .tools: toolTiles
        }
    }

    private func tile(_ symbol: String, _ label: String, active: Bool = false, _ action: @escaping () -> Void) -> some View {
        TileButton(symbol: symbol, label: label, active: active, size: size, action: action)
    }

    private func glyph(_ g: String, _ font: Font, _ label: String, active: Bool = false, _ action: @escaping () -> Void) -> some View {
        TileButton(glyph: g, font: font, label: label, active: active, size: size, action: action)
    }

    private var separator: some View {
        Rectangle().fill(Color.black.opacity(0.35)).frame(width: 1, height: size - 8)
            .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1).offset(x: 1) }
    }

    // MARK: 开始

    @ViewBuilder
    private var homeTiles: some View {
        Group {
        tile("arrow.uturn.backward", tr("撤销", "Undo")) { ed.call("cmd", "undo") }
        tile("arrow.uturn.forward", tr("重做", "Redo")) { ed.call("cmd", "redo") }
        separator
        glyph("B", .system(size: 19, weight: .heavy, design: .serif), tr("加粗", "Bold"), active: ed.state.bold) { ed.call("cmd", "bold") }
        glyph("I", .system(size: 19, weight: .regular, design: .serif).italic(), tr("倾斜", "Italic"), active: ed.state.italic) { ed.call("cmd", "italic") }
        tile("underline", tr("下划线", "Underline"), active: ed.state.underline) { ed.call("cmd", "underline") }
        tile("strikethrough", tr("删除线", "Strike"), active: ed.state.strike) { ed.call("cmd", "strikeThrough") }
        tile("textformat.superscript", tr("上标", "Super"), active: ed.state.sup) { ed.call("cmd", "superscript") }
        tile("textformat.subscript", tr("下标", "Sub"), active: ed.state.sub) { ed.call("cmd", "subscript") }
        }
        separator
        Group {
        glyph("Aa", .system(size: 15, weight: .bold, design: .serif), ed.state.fontName.isEmpty ? tr("字体", "Font") : ed.state.fontName) { sheet = .font }
        glyph(ed.state.sizePt.isEmpty ? "11" : ed.state.sizePt, RT.font(15, .bold), tr("字号", "Size")) { sheet = .size }
        glyph("A+", .system(size: 16, weight: .bold, design: .serif), tr("增大", "Grow")) { ed.call("growFont", 1.0) }
        glyph("A−", .system(size: 16, weight: .bold, design: .serif), tr("缩小", "Shrink")) { ed.call("growFont", -1.0) }
        separator
        tile("paintpalette", tr("字体颜色", "Color")) { sheet = .color }
        tile("highlighter", tr("突出显示", "Highlight")) { sheet = .highlight }
        tile("paintbrush.pointed", ed.state.painter ? tr("应用格式", "Apply") : tr("格式刷", "Painter"), active: ed.state.painter) {
            if ed.state.painter { ed.call("pasteFormat") } else { ed.call("copyFormat") }
        }
        tile("eraser", tr("清除格式", "Clear")) { ed.call("clear") }
        }
    }

    // MARK: 段落

    @ViewBuilder
    private var paragraphTiles: some View {
        Group {
        tile("list.bullet", tr("项目符号", "Bullets"), active: ed.state.ul) { ed.call("cmd", "insertUnorderedList") }
        tile("circle.grid.2x1", tr("符号样式", "Bullet Style")) { sheet = .bullets }
        tile("list.number", tr("编号", "Numbering"), active: ed.state.ol) { ed.call("cmd", "insertOrderedList") }
        tile("textformat.123", tr("编号样式", "Num Style")) { sheet = .numbering }
        separator
        tile("decrease.indent", tr("减少缩进", "Outdent")) { ed.call("cmd", "outdent") }
        tile("increase.indent", tr("增加缩进", "Indent")) { ed.call("cmd", "indent") }
        }
        separator
        Group {
        tile("text.alignleft", tr("左对齐", "Left"), active: ed.state.align == "left") { ed.call("cmd", "justifyLeft") }
        tile("text.aligncenter", tr("居中", "Center"), active: ed.state.align == "center") { ed.call("cmd", "justifyCenter") }
        tile("text.alignright", tr("右对齐", "Right"), active: ed.state.align == "right") { ed.call("cmd", "justifyRight") }
        tile("text.justify", tr("两端对齐", "Justify"), active: ed.state.align == "justify") { ed.call("cmd", "justifyFull") }
        separator
        tile("arrow.up.and.down.text.horizontal", tr("行距", "Spacing")) { sheet = .spacing }
        tile("textformat.alt", tr("样式", "Styles")) { sheet = .styles }
        tile("text.quote", tr("引用块", "Quote"), active: ed.state.block == "blockquote") { ed.call("block", "blockquote") }
        }
    }

    // MARK: 插入

    @ViewBuilder
    private var insertTiles: some View {
        Group {
        tile("link", tr("链接", "Link"), active: !ed.state.link.isEmpty) { sheet = .link }
        tile("link.badge.plus", tr("取消链接", "Unlink")) { ed.call("unlink") }
        separator
        tile("photo", tr("插入图片", "Picture")) { onInlineImage() }
        tile("paperclip", tr("附件", "Attach")) { onActionSheet(tr("添加附件", "Attach"), attachActions) }
        tile("tablecells", tr("表格", "Table")) { sheet = .table }
        }
        separator
        Group {
        tile("checklist", tr("待办清单", "Checklist")) { ed.call("bullet", "\"☐  \"") }
        tile("minus", tr("分隔线", "Line")) { ed.call("cmd", "insertHorizontalRule") }
        tile("calendar", tr("日期时间", "Date")) { ed.call("cmd", "insertText", Fmt.long(Date())) }
        tile("signature", tr("签名", "Signature")) { onSignature() }
        tile("character", tr("符号", "Symbol")) { sheet = .symbols }
        }
    }

    // MARK: 表格

    @ViewBuilder
    private var tableTiles: some View {
        tile("tablecells.badge.ellipsis", tr("插入表格", "Insert")) { sheet = .table }
        separator
        Group {
            tile("arrow.up.square", tr("上方插行", "Row Above")) { ed.call("addRow", false) }
            tile("arrow.down.square", tr("下方插行", "Row Below")) { ed.call("addRow", true) }
            tile("arrow.left.square", tr("左侧插列", "Col Left")) { ed.call("addCol", false) }
            tile("arrow.right.square", tr("右侧插列", "Col Right")) { ed.call("addCol", true) }
            tile("minus.square", tr("删除行", "Del Row")) { ed.call("delRow") }
            tile("minus.square.fill", tr("删除列", "Del Col")) { ed.call("delCol") }
            tile("arrow.triangle.merge", tr("向右合并", "Merge")) { ed.call("merge") }
            tile("drop.fill", tr("底纹", "Shading")) { sheet = .cellFill }
            tile("square.dashed", tr("无边框", "No Border")) { ed.call("border", "1px dashed #d0d0d0") }
            tile("square", tr("细边框", "Thin")) { ed.call("border", "1px solid #8c8c8c") }
        }
        .disabled(!ed.state.inTable)
        Group {
            tile("square.fill", tr("粗边框", "Thick")) { ed.call("border", "2px solid #000000") }
            tile("arrow.left.and.right", tr("占满宽度", "Full Width")) { ed.call("tableWidth", true) }
            tile("arrow.right.and.line.vertical.and.arrow.left", tr("自动宽度", "Auto Width")) { ed.call("tableWidth", false) }
            tile("trash", tr("删除表格", "Delete")) { ed.call("delTable") }
        }
        .disabled(!ed.state.inTable)
    }

    // MARK: 工具

    @ViewBuilder
    private var toolTiles: some View {
        tile("sparkles", tr("AI 写作", "AI Write")) { sheet = .ai }
        tile("magnifyingglass", tr("查找替换", "Find")) { sheet = .find }
        glyph("Aa", .system(size: 16, weight: .bold), tr("大小写", "Case")) { onActionSheet(tr("更改大小写", "Change Case"), caseActions) }
        separator
        tile(priority == .low ? "arrow.down" : "exclamationmark",
             priority == .high ? tr("重要：高", "High") : priority == .low ? tr("重要：低", "Low") : tr("重要性", "Priority"),
             active: priority != .normal) { onActionSheet(tr("重要性", "Importance"), priorityActions) }
        tile("checkmark.seal", tr("已读回执", "Receipt"), active: readReceipt) { readReceipt.toggle() }
        separator
        tile("tray.and.arrow.down", tr("存草稿", "Save Draft")) { onSaveDraft() }
    }
}

// MARK: - 选项面板

struct FontOption: Identifiable {
    let name: String
    let css: String
    let preview: String
    var id: String { name }

    static func matches(_ current: String, _ f: FontOption) -> Bool {
        let first = (f.css.split(separator: ",").first.map(String.init) ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
        return !current.isEmpty && current.caseInsensitiveCompare(first) == .orderedSame
    }

    static let all: [FontOption] = [
        FontOption(name: tr("默认（Calibri）", "Default (Calibri)"), css: "Calibri, 'Microsoft YaHei', 'PingFang SC', Arial, sans-serif", preview: "Helvetica"),
        FontOption(name: "微软雅黑 YaHei", css: "'Microsoft YaHei', 'PingFang SC', sans-serif", preview: "PingFang SC"),
        FontOption(name: "苹方 PingFang", css: "'PingFang SC', 'Microsoft YaHei', sans-serif", preview: "PingFang SC"),
        FontOption(name: "宋体 SimSun", css: "SimSun, 'Songti SC', serif", preview: "Songti SC"),
        FontOption(name: "黑体 SimHei", css: "SimHei, 'Heiti SC', sans-serif", preview: "Heiti SC"),
        FontOption(name: "楷体 KaiTi", css: "KaiTi, 'Kaiti SC', STKaiti, serif", preview: "Kaiti SC"),
        FontOption(name: "仿宋 FangSong", css: "FangSong, STFangsong, serif", preview: "STFangsong"),
        FontOption(name: "Arial", css: "Arial, Helvetica, sans-serif", preview: "Arial"),
        FontOption(name: "Calibri", css: "Calibri, Carlito, sans-serif", preview: "Helvetica Neue"),
        FontOption(name: "Cambria", css: "Cambria, Georgia, serif", preview: "Georgia"),
        FontOption(name: "Georgia", css: "Georgia, serif", preview: "Georgia"),
        FontOption(name: "Helvetica", css: "Helvetica, Arial, sans-serif", preview: "Helvetica"),
        FontOption(name: "Segoe UI", css: "'Segoe UI', -apple-system, sans-serif", preview: "Avenir Next"),
        FontOption(name: "Tahoma", css: "Tahoma, Verdana, sans-serif", preview: "Verdana"),
        FontOption(name: "Times New Roman", css: "'Times New Roman', Times, serif", preview: "Times New Roman"),
        FontOption(name: "Trebuchet MS", css: "'Trebuchet MS', sans-serif", preview: "Trebuchet MS"),
        FontOption(name: "Verdana", css: "Verdana, sans-serif", preview: "Verdana"),
        FontOption(name: "Courier New", css: "'Courier New', Courier, monospace", preview: "Courier New"),
        FontOption(name: "Garamond", css: "Garamond, 'Times New Roman', serif", preview: "Baskerville"),
    ]
}

/// 编辑器的所有弹出面板。
struct EditorSheetView: View {
    let sheet: EditorSheet
    @ObservedObject var ed: EditorController
    var aiContext: String
    var onSubject: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch sheet {
        case .font: FontSheet(ed: ed)
        case .size: SizeSheet(ed: ed)
        case .color: ColorSheet(title: tr("字体颜色", "Font Color"), autoLabel: tr("自动（黑色）", "Automatic (Black)"), autoValue: "#000000") { ed.call("color", $0) }
        case .highlight: ColorSheet(title: tr("突出显示颜色", "Highlight Color"), autoLabel: tr("无颜色", "No Color"), autoValue: "", highlight: true) { ed.call("highlight", $0) }
        case .cellFill: ColorSheet(title: tr("单元格底纹", "Cell Shading"), autoLabel: tr("无颜色", "No Color"), autoValue: "") { ed.call("cellFill", $0) }
        case .bullets: BulletSheet(ed: ed)
        case .numbering: NumberingSheet(ed: ed)
        case .spacing: SpacingSheet(ed: ed)
        case .styles: StylesSheet(ed: ed)
        case .link: LinkSheet(ed: ed)
        case .table: TableSheet(ed: ed)
        case .symbols: SymbolSheet(ed: ed)
        case .find: FindSheet(ed: ed)
        case .ai: AIWriterSheet(ed: ed, context: aiContext, onSubject: onSubject)
        }
    }
}

private struct OptionRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    let content: Content

    init(selected: Bool = false, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.selected = selected
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            HStack {
                content
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { RetroDivider(dotted: true).opacity(0.6) }
        }
        .buttonStyle(InvertOnPressStyle())
    }
}

struct FontSheet: View {
    @ObservedObject var ed: EditorController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RetroPanel(tr("字体", "Font")) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(FontOption.all) { f in
                        OptionRow(selected: FontOption.matches(ed.state.fontName, f)) {
                            ed.call("cmd", "fontName", f.css)
                            dismiss()
                        } content: {
                            Text(f.name).font(.custom(f.preview, size: 17))
                        }
                    }
                }
            }
        }
        .retroSheetStyle()
    }
}

struct SizeSheet: View {
    @ObservedObject var ed: EditorController
    @Environment(\.dismiss) private var dismiss
    private let sizes: [Double] = [8, 9, 10, 10.5, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 32, 36, 48, 72]

    var body: some View {
        RetroPanel(tr("字号（磅）", "Font Size (pt)")) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                    ForEach(sizes, id: \.self) { s in
                        let label = s == s.rounded() ? String(Int(s)) : String(s)
                        Button {
                            ed.call("fontSize", s)
                            dismiss()
                        } label: {
                            Text(label)
                                .font(RT.font(16, .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(TileStyle(active: ed.state.sizePt == label))
                    }
                }
                .padding(16)
            }
        }
        .retroSheetStyle()
    }
}

struct ColorSheet: View {
    let title: String
    let autoLabel: String
    let autoValue: String
    var highlight = false
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var custom: Color = .red

    private static let theme = ["#FFFFFF", "#000000", "#E7E6E6", "#44546A", "#4472C4", "#ED7D31", "#A5A5A5", "#FFC000", "#5B9BD5", "#70AD47"]
    private static let standard = ["#C00000", "#FF0000", "#FFC000", "#FFFF00", "#92D050", "#00B050", "#00B0F0", "#0070C0", "#002060", "#7030A0"]
    private static let highlights = ["#FFFF00", "#00FF00", "#00FFFF", "#FF00FF", "#0000FF", "#FF0000", "#000080", "#008080", "#008000", "#800080", "#800000", "#808000", "#808080", "#C0C0C0", "#000000"]

    private var grid: [[String]] {
        if highlight { return [Array(Self.highlights.prefix(8)), Array(Self.highlights.suffix(7))] }
        let shades: [Double] = [0, 0.8, 0.6, 0.4, -0.25, -0.5]
        return shades.map { amt in Self.theme.map { amt == 0 ? $0 : HexColor.mix($0, ($0 == "#FFFFFF" && amt > 0) ? -amt / 4 : amt) } }
    }

    var body: some View {
        RetroPanel(title) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Button {
                        onPick(autoValue)
                        dismiss()
                    } label: {
                        HStack {
                            Rectangle()
                                .fill(autoValue.isEmpty ? Color.clear : HexColor.color(autoValue))
                                .frame(width: 20, height: 20)
                                .overlay(Rectangle().stroke(Color.ink, lineWidth: 1))
                                .overlay { if autoValue.isEmpty { Image(systemName: "nosign").font(.system(size: 12)) } }
                            Text(autoLabel).font(RT.font(13, .bold))
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(TileStyle())

                    Text(highlight ? tr("突出显示", "Highlight") : tr("主题颜色", "Theme Colors")).font(RT.font(12, .bold))
                    swatches(grid)
                    if !highlight {
                        Text(tr("标准色", "Standard Colors")).font(RT.font(12, .bold))
                        swatches([Self.standard])
                    }
                    HStack {
                        ColorPicker(tr("其他颜色…", "More Colors…"), selection: $custom, supportsOpacity: false)
                            .font(RT.font(13, .bold))
                        Button(tr("使用", "Use")) {
                            onPick(HexColor.hex(custom))
                            dismiss()
                        }
                        .buttonStyle(RetroButtonStyle(compact: true))
                    }
                }
                .padding(16)
            }
        }
        .retroSheetStyle()
    }

    private func swatches(_ rows: [[String]]) -> some View {
        VStack(spacing: 6) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(rows[r], id: \.self) { hex in
                        Button {
                            onPick(hex)
                            dismiss()
                        } label: {
                            Rectangle()
                                .fill(HexColor.color(hex))
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(Rectangle().stroke(Color.ink, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct BulletSheet: View {
    @ObservedObject var ed: EditorController
    @Environment(\.dismiss) private var dismiss
    private let options: [(String, String)] = [
        ("disc", "●"), ("circle", "○"), ("square", "■"),
        ("\"◆  \"", "◆"), ("\"➤  \"", "➤"), ("\"✓  \"", "✓"),
        ("\"★  \"", "★"), ("\"–  \"", "–"), ("\"→  \"", "→"),
        ("\"☐  \"", "☐"), ("\"❖  \"", "❖"), ("\"•  \"", "•"),
    ]

    var body: some View {
        RetroPanel(tr("项目符号样式", "Bullet Library")) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
                    ForEach(options.indices, id: \.self) { i in
                        let opt = options[i]
                        Button {
                            ed.call("bullet", opt.0)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(0..<3, id: \.self) { _ in
                                    HStack(spacing: 6) {
                                        Text(opt.1).font(.system(size: 13))
                                        Rectangle().fill(Color.white.opacity(0.75)).frame(height: 2)
                                    }
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(TileStyle())
                    }
                }
                .padding(16)
            }
        }
        .retroSheetStyle()
    }
}

struct NumberingSheet: View {
    @ObservedObject var ed: EditorController
    @Environment(\.dismiss) private var dismiss
    private let options: [(String, [String])] = [
        ("decimal", ["1.", "2.", "3."]),
        ("decimal-leading-zero", ["01.", "02.", "03."]),
        ("lower-alpha", ["a.", "b.", "c."]),
        ("upper-alpha", ["A.", "B.", "C."]),
        ("lower-roman", ["i.", "ii.", "iii."]),
        ("upper-roman", ["I.", "II.", "III."]),
        ("cjk-ideographic", ["一、", "二、", "三、"]),
        ("\"(\" counter(list-item) \") \"", ["(1)", "(2)", "(3)"]),
    ]

    var body: some View {
        RetroPanel(tr("编号样式", "Numbering Library")) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 14) {
                    ForEach(options.indices, id: \.self) { i in
                        let opt = options[i]
                        Button {
                            ed.call("number", opt.0)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(opt.1, id: \.self) { n in
                                    HStack(spacing: 6) {
                                        Text(n).font(RT.font(12, .bold)).frame(width: 30, alignment: .leading)
                                        Rectangle().fill(Color.white.opacity(0.75)).frame(height: 2)
                                    }
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(TileStyle())
                    }
                }
                .padding(16)
            }
        }
        .retroSheetStyle()
    }
}

struct SpacingSheet: View {
    @ObservedObject var ed: EditorController
    @Environment(\.dismiss) private var dismiss
    private let lines = ["1.0", "1.15", "1.5", "2.0", "2.5", "3.0"]
    private let after: [(String, String)] = [("0", "0"), ("6pt", "6 pt"), ("12pt", "12 pt"), ("18pt", "18 pt")]

    var body: some View {
        RetroPanel(tr("行距与段落间距", "Line & Paragraph Spacing")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(tr("行距", "Line Spacing")).font(RT.font(12, .bold))
                    FlowRow(spacing: 10) {
                        ForEach(lines, id: \.self) { v in
                            Button(v) {
                                ed.call("lineHeight", v)
                                dismiss()
                            }
                            .buttonStyle(RetroButtonStyle(compact: true))
                        }
                    }
                    Text(tr("段后间距", "Space After Paragraph")).font(RT.font(12, .bold))
                    FlowRow(spacing: 10) {
                        ForEach(after.indices, id: \.self) { i in
                            let v = after[i]
                            Button(v.1) {
                                ed.call("spaceAfter", v.0)
                                dismiss()
                            }
                            .buttonStyle(RetroButtonStyle(compact: true))
                        }
                    }
                }
                .padding(16)
            }
        }
        .retroSheetStyle()
    }
}

struct StylesSheet: View {
    @ObservedObject var ed: EditorController
    @Environment(\.dismiss) private var dismiss

    private var options: [(String, String, Font)] {
        [
            ("div", tr("正文", "Normal"), .system(size: 15)),
            ("h1", tr("标题 1", "Heading 1"), .system(size: 24, weight: .bold)),
            ("h2", tr("标题 2", "Heading 2"), .system(size: 20, weight: .bold)),
            ("h3", tr("标题 3", "Heading 3"), .system(size: 17, weight: .bold)),
            ("h4", tr("标题 4", "Heading 4"), .system(size: 15, weight: .bold)),
            ("blockquote", tr("引用", "Quote"), .system(size: 15).italic()),
            ("pre", tr("代码 / 等宽", "Code"), .system(size: 14, design: .monospaced)),
        ]
    }

    var body: some View {
        RetroPanel(tr("样式", "Styles")) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(options.indices, id: \.self) { i in
                        let opt = options[i]
                        OptionRow(selected: ed.state.block == opt.0) {
                            ed.call("block", opt.0)
                            dismiss()
                        } content: {
                            Text(opt.1).font(opt.2)
                        }
                    }
                }
            }
        }
        .retroSheetStyle()
    }
}

struct LinkSheet: View {
    @ObservedObject var ed: EditorController
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var url = ""

    var body: some View {
        RetroPanel(tr("超链接", "Hyperlink")) {
            VStack(alignment: .leading, spacing: 14) {
                RetroGroup("") {
                    RetroField(label: tr("显示文字", "Text"), text: $text, placeholder: tr("可留空", "Optional"))
                    RetroField(label: tr("地址", "Address"), text: $url, placeholder: "https://… / name@…", keyboard: .URL)
                }
                HStack(spacing: 12) {
                    if !ed.state.link.isEmpty {
                        Button(tr("删除链接", "Remove")) {
                            ed.call("unlink")
                            dismiss()
                        }
                        .buttonStyle(RetroButtonStyle(compact: true))
                    }
                    Spacer()
                    Button(tr("确定", "OK")) {
                        apply()
                        dismiss()
                    }
                    .buttonStyle(RetroButtonStyle(isDefault: true))
                    .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(16)
        }
        .retroSheetStyle()
        .task {
            url = ed.state.link
            text = (await ed.callResult("linkText") as? String) ?? ""
        }
    }

    private func apply() {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.contains(":") {
            u = u.contains("@") && !u.contains("/") ? "mailto:" + u : "https://" + u
        }
        ed.call("link", u, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct TableSheet: View {
    @ObservedObject var ed: EditorController
    @Environment(\.dismiss) private var dismiss
    @State private var rows = 3
    @State private var cols = 3
    @State private var header = true
    @State private var full = true
    @State private var border = "1px solid #8c8c8c"

    var body: some View {
        RetroPanel(tr("插入表格", "Insert Table")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    RetroGroup("") {
                        Stepper(value: $rows, in: 1...30) {
                            Text(tr("行数：\(rows)", "Rows: \(rows)")).font(RT.font(15, .bold))
                        }
                        Stepper(value: $cols, in: 1...12) {
                            Text(tr("列数：\(cols)", "Columns: \(cols)")).font(RT.font(15, .bold))
                        }
                        preview
                        RetroCheckbox(label: tr("首行作为标题行", "Header row"), isOn: $header)
                        RetroCheckbox(label: tr("宽度占满整行", "Full width"), isOn: $full)
                        RetroRadio(label: tr("边框", "Borders"),
                                   options: [("1px solid #8c8c8c", tr("细线", "Thin")),
                                             ("2px solid #000000", tr("粗线", "Thick")),
                                             ("1px dashed #d0d0d0", tr("无", "None"))],
                                   selection: $border, labelWidth: 60)
                    }
                    HStack {
                        Spacer()
                        Button(tr("插入", "Insert")) {
                            ed.call("table", rows, cols, header, full, border)
                            dismiss()
                        }
                        .buttonStyle(RetroButtonStyle(isDefault: true))
                    }
                }
                .padding(16)
            }
        }
        .retroSheetStyle()
    }

    private var preview: some View {
        VStack(spacing: 0) {
            ForEach(0..<min(rows, 8), id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<min(cols, 8), id: \.self) { _ in
                        Rectangle()
                            .fill(header && r == 0 ? Color.shade : Color.paper)
                            .frame(height: 16)
                            .overlay(Rectangle().stroke(Color.ink, lineWidth: 0.5))
                    }
                }
            }
        }
        .frame(maxWidth: 260)
    }
}

struct SymbolSheet: View {
    @ObservedObject var ed: EditorController
    @Environment(\.dismiss) private var dismiss
    private let symbols = Array("©®™€£¥¢§¶°±×÷≈≠≤≥∞√∑πµ‰←→↑↓↔⇒✓✔✗✘★☆●○■□◆◇▲△▼▽•…—–「」『』【】《》〈〉“”‘’№℃♀♂☎✉✈☀☁☂☺♥♦♣♠").map(String.init)

    var body: some View {
        RetroPanel(tr("符号", "Symbols")) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                    ForEach(symbols, id: \.self) { s in
                        Button {
                            ed.call("cmd", "insertText", s)
                            dismiss()
                        } label: {
                            Text(s).font(.system(size: 20)).frame(maxWidth: .infinity, minHeight: 38)
                        }
                        .buttonStyle(TileStyle(depth: 2))
                    }
                }
                .padding(14)
            }
        }
        .retroSheetStyle()
    }
}

struct FindSheet: View {
    @ObservedObject var ed: EditorController
    @State private var find = ""
    @State private var replace = ""
    @State private var caseSensitive = false
    @State private var result: String?

    var body: some View {
        RetroPanel(tr("查找和替换", "Find & Replace")) {
            VStack(alignment: .leading, spacing: 14) {
                RetroGroup("") {
                    RetroField(label: tr("查找", "Find"), text: $find)
                    RetroField(label: tr("替换为", "Replace"), text: $replace)
                    RetroCheckbox(label: tr("区分大小写", "Match case"), isOn: $caseSensitive)
                }
                HStack(spacing: 12) {
                    Button(tr("查找下一个", "Find Next")) {
                        Task {
                            let ok = (await ed.callResult("findNext", find, caseSensitive) as? Bool) ?? false
                            result = ok ? nil : tr("没有找到。", "Not found.")
                        }
                    }
                    .buttonStyle(RetroButtonStyle(compact: true))
                    Spacer()
                    Button(tr("全部替换", "Replace All")) {
                        Task {
                            let n = (await ed.callResult("replaceAll", find, replace, caseSensitive) as? Int) ?? 0
                            result = tr("已替换 \(n) 处。", "Replaced \(n).")
                        }
                    }
                    .buttonStyle(RetroButtonStyle(isDefault: true, compact: true))
                    .disabled(find.isEmpty)
                }
                if let r = result {
                    Text(r).font(RT.font(12))
                }
            }
            .padding(16)
        }
        .retroSheetStyle()
    }
}
