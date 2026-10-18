import SwiftUI
import UIKit
import PhotosUI

/// 签名编辑页：富文本（字体、颜色、链接、Logo 图片……），可分别设置新邮件 / 回复转发是否自动添加。
struct SignatureEditorView: View {
    let account: MailAccount
    let onDone: (MailAccount) -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ed = EditorController()
    @State private var onNew = true
    @State private var onReply = true
    @State private var sheet: EditorSheet?
    @State private var priority: MailPriority = .normal
    @State private var receipt = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var ribbonSheet: RibbonSheet?
    @State private var loaded = false
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            IOS3NavBar(title: tr("签名", "Signature")) {
                Button(tr("取消", "Cancel")) { dismiss() }
                    .buttonStyle(BarButtonStyle())
            } trailing: {
                Button(tr("存储", "Save")) { save() }
                    .buttonStyle(BarButtonStyle(kind: .done))
            }
            VStack(spacing: 0) {
                HStack {
                    Text(tr("新邮件", "New Mail")).font(RT.font(15, .bold))
                    Spacer()
                    IOS3Switch(isOn: $onNew)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                RetroDivider()
                HStack {
                    Text(tr("回复和转发", "Replies & Forwards")).font(RT.font(15, .bold))
                    Spacer()
                    IOS3Switch(isOn: $onReply)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                RetroDivider()
                HStack(spacing: 10) {
                    Text(tr("可以设置字体、颜色、链接，插入 Logo 图片；也可以从别的邮件里复制签名粘贴进来。",
                            "Format text, add links or a logo image — or paste a signature copied from another email."))
                        .font(RT.font(12))
                        .foregroundColor(IOS3.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(tr("清空", "Clear")) { confirmClear = true }
                        .buttonStyle(RetroButtonStyle(compact: true))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                RetroDivider()
            }
            .background(IOS3.cell)
            RichEditorView(controller: ed, placeholder: tr("在此输入签名…", "Type your signature…"))
            FormatRibbon(ed: ed, sheet: $sheet, priority: $priority, readReceipt: $receipt,
                         onInlineImage: { showPhotos = true },
                         onAttachPhoto: { showPhotos = true },
                         onAttachFile: {},
                         onSignature: {},
                         onSaveDraft: { save() },
                         onSend: { save() },
                         onActionSheet: { title, actions in ribbonSheet = RibbonSheet(title: title, actions: actions) })
        }
        .foregroundColor(.ink)
        .background(IOS3.cell.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $sheet) { s in
            EditorSheetView(sheet: s, ed: ed, aiContext: "") { _ in }
                .preferredColorScheme(settings.colorScheme)
        }
        .photosPicker(isPresented: $showPhotos, selection: $photos, maxSelectionCount: 1, matching: .images)
        .onChange(of: photos) { items in
            guard let item = items.first else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    // 签名里的 Logo 不需要太大
                    let small = ComposeView.downscale(img, maxSide: 600)
                    if let png = small.pngData(), png.count < 400_000 {
                        ed.call("image", "data:image/png;base64,\(png.base64EncodedString())")
                    } else if let jpg = small.jpegData(compressionQuality: 0.85) {
                        ed.call("image", "data:image/jpeg;base64,\(jpg.base64EncodedString())")
                    }
                }
                photos = []
            }
        }
        .ios3ActionSheet(isPresented: Binding(get: { ribbonSheet != nil }, set: { if !$0 { ribbonSheet = nil } }),
                         title: ribbonSheet?.title, actions: ribbonSheet?.actions ?? [])
        .ios3ActionSheet(isPresented: $confirmClear, actions: [
            SheetAction(tr("清空签名", "Clear Signature"), role: .destructive) { ed.call("setHTML", "") },
        ])
        .onAppear {
            guard !loaded else { return }
            loaded = true
            onNew = account.signatureOnNew ?? true
            onReply = account.signatureOnReply ?? true
            ed.setInitialHTML(account.signatureBodyHTML)
        }
    }

    private func save() {
        Task {
            let html = await ed.html()
            let text = await ed.text()
            var a = account
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasImage = html.range(of: "<img", options: .caseInsensitive) != nil
            if trimmedText.isEmpty && !hasImage {
                a.signatureRich = nil
                a.signature = ""
            } else {
                a.signatureRich = html
                a.signature = trimmedText
            }
            a.signatureOnNew = onNew
            a.signatureOnReply = onReply
            onDone(a)
            dismiss()
        }
    }
}
