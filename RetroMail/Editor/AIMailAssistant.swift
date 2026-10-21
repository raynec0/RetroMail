import SwiftUI
import UIKit

/// 邮件 AI 助手：点了才用。先给出总结（要点、待办、截止日期、需要你回复什么），
/// 然后可以就这封邮件 / 这个会话继续提问，或一键起草回复。
struct AIMailAssistant: View {
    let title: String
    /// 邮件内容（会话里每封的新内容，已去掉引用）
    let context: String
    let onDraftReply: (String) -> Void

    struct Turn: Identifiable, Equatable {
        let id = UUID()
        let mine: Bool
        let text: String
    }

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var turns: [Turn] = []
    @State private var input = ""
    @State private var busy = false
    @State private var error: String?
    @State private var started = false
    @FocusState private var focused: Bool

    private var quickQuestions: [String] {
        [
            tr("我需要做什么？有截止时间吗？", "What do I need to do, and by when?"),
            tr("帮我起草一封回复", "Draft a reply for me"),
            tr("对方的语气和态度怎么样？", "What's the sender's tone?"),
            tr("有哪些风险或需要注意的地方？", "Any risks or things to watch out for?"),
            tr("翻译成中文", "Translate into English"),
            tr("列出邮件里提到的人、日期和数字", "List the people, dates and numbers mentioned"),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            IOS3NavBar(title: tr("AI 助手", "AI Assistant")) {
                Button(tr("关闭", "Close")) { dismiss() }.buttonStyle(BarButtonStyle())
            } trailing: {
                Button(tr("重来", "Reset")) {
                    turns = []
                    summarize()
                }
                .buttonStyle(BarButtonStyle())
                .disabled(busy)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title)
                            .font(RT.font(15, .bold))
                            .foregroundColor(IOS3.groupHeader)
                            .shadow(color: IOS3.groupHeaderShadow, radius: 0, x: 0, y: 1)
                            .lineLimit(2)
                            .padding(.horizontal, 4)
                        if !AIConfig.isConfigured {
                            notConfigured
                        }
                        ForEach(turns) { t in bubble(t) }
                        if busy {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(tr("AI 正在阅读邮件…", "Reading…")).font(RT.font(13)).foregroundColor(IOS3.groupHeader)
                            }
                            .padding(.horizontal, 6)
                            AIHandoffBanner()
                        }
                        if !busy && !turns.isEmpty {
                            FlowRow(spacing: 6) {
                                ForEach(quickQuestions, id: \.self) { q in
                                    Button(q) { ask(q) }
                                        .buttonStyle(RetroButtonStyle(compact: true))
                                }
                            }
                            .padding(.top, 4)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(10)
                }
                .onChange(of: turns) { _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            inputBar
        }
        .foregroundColor(.ink)
        .background(PinstripeBackground().ignoresSafeArea())
        .retroAlert($error)
        .onAppear {
            guard !started else { return }
            started = true
            if AIConfig.isConfigured { summarize() }
        }
        .onDisappear { AIHandoff.shared.cancel() }
    }

    private var notConfigured: some View {
        Text(tr("还没有设置 AI。请到 设置 → AI 助手 选择一种方式（ChatGPT 订阅登录、Apple 本机 AI、API Key 等）。",
                "AI isn't set up. Go to Settings → AI Assistant and choose a provider (ChatGPT sign-in, Apple on-device, API key…)."))
            .font(RT.font(13))
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(IOS3.cell))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(IOS3.groupBorder, lineWidth: 1))
    }

    private func bubble(_ t: Turn) -> some View {
        HStack {
            if t.mine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                Text(t.text)
                    .font(RT.font(15))
                    .foregroundColor(t.mine ? .white : .ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !t.mine {
                    HStack(spacing: 8) {
                        Button(tr("复制", "Copy")) {
                            UIPasteboard.general.string = t.text
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            MailCenter.shared.showToast(MailToast(text: tr("已复制", "Copied"), undo: nil))
                        }
                        .buttonStyle(RetroButtonStyle(compact: true))
                        Button(tr("用这段回复", "Use as Reply")) {
                            onDraftReply(t.text)
                        }
                        .buttonStyle(RetroButtonStyle(compact: true))
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(t.mine
                          ? AnyShapeStyle(LinearGradient(colors: [HexColor.color("#5F9BEA"), HexColor.color("#2D69C9")], startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(IOS3.cell))
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(t.mine ? Color.clear : IOS3.groupBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)
            if !t.mine { Spacer(minLength: 20) }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(tr("就这封邮件问点什么…", "Ask about this email…"), text: $input, axis: .vertical)
                .font(RT.font(15))
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white))
                .overlay(Capsule().stroke(HexColor.color("#8E98A5"), lineWidth: 1))
                .foregroundColor(.black)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { send() }
            Button(tr("发送", "Send")) { send() }
                .buttonStyle(BarButtonStyle(kind: .done))
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(IOS3.bar)
    }

    private func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        input = ""
        ask(q)
    }

    private var langLine: String {
        tr("Answer in Simplified Chinese unless the user writes in another language.", "Answer in English unless the user writes in another language.")
    }

    private var system: String {
        """
        You are an assistant inside an email app, helping a busy professional understand and act on email.
        Only use facts that are in the email(s) below; if something isn't stated, say so. Never invent names, dates or numbers.
        Be concise and specific. Plain text only: no markdown headings, no tables; "- " bullets are fine. \(langLine)
        When asked to draft a reply, output only the reply body, ready to send, in the language of the email.

        EMAIL(S):
        \(String(context.prefix(24000)))
        """
    }

    private func summarize() {
        let prompt = tr("""
        请总结这封邮件 / 这个会话，按下面的小标题输出（没有内容的部分省略）：
        一句话概要：
        要点：
        需要我做的事（谁 / 做什么 / 截止时间）：
        日期和时间：
        需要回复的问题：
        建议的下一步：
        """, """
        Summarize this email / thread using these labels (omit empty ones):
        In one line:
        Key points:
        What I need to do (who / what / by when):
        Dates & times:
        Questions I need to answer:
        Suggested next step:
        """)
        run(prompt, show: false)
    }

    private func ask(_ q: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        turns.append(Turn(mine: true, text: q))
        run(q, show: true)
    }

    private func run(_ question: String, show: Bool) {
        busy = true
        let history = turns.dropLast(show ? 1 : 0).suffix(8).map { ($0.mine ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n\n")
        let user = history.isEmpty ? question : "Conversation so far:\n\(history)\n\nUser: \(question)"
        let sys = system
        Task {
            defer { busy = false }
            do {
                let answer = try await AIClient.complete(system: sys, user: user, maxTokens: 1500)
                turns.append(Turn(mine: false, text: answer))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch AIError.cancelled {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
