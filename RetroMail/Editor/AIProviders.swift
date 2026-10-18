import SwiftUI
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Apple 本机模型（iOS 26 Apple 智能）

enum AppleAI {
    /// nil 表示可以用；否则是不能用的原因。
    static var availability: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return tr("这台设备不支持 Apple 智能。", "This device doesn't support Apple Intelligence.")
                case .appleIntelligenceNotEnabled:
                    return tr("请先在 iOS 设置 → Apple 智能与 Siri 里打开 Apple 智能。", "Turn on Apple Intelligence in iOS Settings → Apple Intelligence & Siri.")
                case .modelNotReady:
                    return tr("Apple 智能模型还在下载，请稍后再试。", "The Apple Intelligence model is still downloading. Try again later.")
                @unknown default:
                    return tr("Apple 智能暂时不可用。", "Apple Intelligence isn't available right now.")
                }
            }
        }
        return tr("Apple 本机 AI 需要 iOS 26。", "Apple on-device AI needs iOS 26.")
        #else
        return tr("这个版本编译时没有包含 Apple 本机 AI（需要用 Xcode 26 编译）。", "This build doesn't include Apple on-device AI (needs Xcode 26).")
        #endif
    }

    static func complete(system: String, user: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if let why = availability { throw AIError.unavailable(why) }
            let session = LanguageModelSession(instructions: system)
            let response = try await session.respond(to: user)
            return response.content
        }
        #endif
        throw AIError.unavailable(availability ?? "")
    }
}

// MARK: - 用订阅：交给官方 AI App 生成，再粘贴回来

/// 不保存、不读取任何登录令牌：把提示词交给你手机上已登录的官方 App（ChatGPT、Claude 等），
/// 用你自己的订阅生成；你复制回答后回到这里粘贴，结果就会接着用在写信 / 总结里。
@MainActor
final class AIHandoff: ObservableObject {
    static let shared = AIHandoff()

    struct Pending: Equatable {
        let app: AIHandoffApp
        let prompt: String
        let changeCount: Int
    }

    @Published private(set) var pending: Pending?
    /// 回到本应用后发现剪贴板有了新内容
    @Published private(set) var clipboardChanged = false
    private var continuation: CheckedContinuation<String, Error>?
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AIHandoff.shared.checkClipboard() }
        }
    }

    static func prompt(system: String, user: String) -> String {
        """
        \(system)

        \(user)

        \(tr("（只输出结果正文，方便我直接复制使用。）", "(Output only the final text so I can copy it directly.)"))
        """
    }

    func run(system: String, user: String, app: AIHandoffApp) async throws -> String {
        cancel()
        let text = Self.prompt(system: system, user: user)
        UIPasteboard.general.string = text
        pending = Pending(app: app, prompt: text, changeCount: UIPasteboard.general.changeCount)
        clipboardChanged = false
        open()
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
        }
    }

    func open() {
        guard let p = pending, let url = p.app.url(prompt: p.prompt) else { return }
        UIApplication.shared.open(url)
    }

    func copyPromptAgain() {
        guard let p = pending else { return }
        UIPasteboard.general.string = p.prompt
        pending = Pending(app: p.app, prompt: p.prompt, changeCount: UIPasteboard.general.changeCount)
        clipboardChanged = false
    }

    private func checkClipboard() {
        guard let p = pending else { return }
        // changeCount 不需要读取内容，不会弹出“允许粘贴”
        clipboardChanged = UIPasteboard.general.changeCount != p.changeCount && UIPasteboard.general.hasStrings
    }

    func finish(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = pending, !t.isEmpty else { return }
        if t == p.prompt.trimmingCharacters(in: .whitespacesAndNewlines) { return }
        pending = nil
        clipboardChanged = false
        continuation?.resume(returning: t)
        continuation = nil
    }

    func cancel() {
        pending = nil
        clipboardChanged = false
        continuation?.resume(throwing: AIError.cancelled)
        continuation = nil
    }
}

/// 等待从官方 App 粘贴回答时显示的面板。
struct AIHandoffBanner: View {
    @ObservedObject private var handoff = AIHandoff.shared

    var body: some View {
        if let p = handoff.pending {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image("mbx-chat").resizable().interpolation(.high).frame(width: 28, height: 28)
                    Text(tr("正在用 \(p.app.name) 生成", "Generating in \(p.app.name)"))
                        .font(RT.font(15, .bold))
                }
                Text(p.app.prefills
                     ? tr("已在 \(p.app.name) 里打开并填好提示词（也已复制，没填上就粘贴进去）。等它回答完，复制回答，回到这里点“粘贴回答”。",
                          "\(p.app.name) was opened with the prompt filled in (it's also copied — paste it if needed). When it's done, copy the answer, come back and tap Paste Answer.")
                     : tr("提示词已复制。在 \(p.app.name) 里粘贴发送，等它回答完，复制回答，回到这里点“粘贴回答”。",
                          "The prompt is copied. Paste it into \(p.app.name), copy the answer when it's done, then come back and tap Paste Answer."))
                    .font(RT.font(12))
                    .fixedSize(horizontal: false, vertical: true)
                if handoff.clipboardChanged {
                    Text(tr("✓ 检测到你复制了新内容", "✓ New copied text detected"))
                        .font(RT.font(12, .bold))
                        .foregroundColor(HexColor.color("#2E7D32"))
                }
                HStack(spacing: 8) {
                    PasteButton(payloadType: String.self) { strings in
                        let text = strings.joined(separator: "\n")
                        Task { @MainActor in AIHandoff.shared.finish(text) }
                    }
                    .buttonBorderShape(.roundedRectangle)
                    .labelStyle(.titleAndIcon)
                    .tint(IOS3.dateBlue)
                    Button(tr("再打开", "Reopen")) { handoff.open() }
                        .buttonStyle(RetroButtonStyle(compact: true))
                    Button(tr("复制提示词", "Copy Prompt")) { handoff.copyPromptAgain() }
                        .buttonStyle(RetroButtonStyle(compact: true))
                    Spacer(minLength: 0)
                    Button(tr("取消", "Cancel")) { handoff.cancel() }
                        .buttonStyle(RetroButtonStyle(compact: true))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(IOS3.cell))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(IOS3.dateBlue, lineWidth: 1.5))
        }
    }
}
