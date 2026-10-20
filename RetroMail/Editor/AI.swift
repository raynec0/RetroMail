import SwiftUI
import UIKit

// MARK: - 配置

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case chatgpt, openai, anthropic, apple, handoff
    var id: String { rawValue }

    var label: String {
        switch self {
        case .chatgpt: return tr("ChatGPT 订阅（账号登录）", "ChatGPT Subscription (Sign In)")
        case .openai: return tr("OpenAI 兼容", "OpenAI-compatible")
        case .anthropic: return "Anthropic"
        case .apple: return tr("Apple 本机 AI", "Apple On-Device")
        case .handoff: return tr("用我的订阅（AI App）", "My Subscription (AI App)")
        }
    }

    var detail: String {
        switch self {
        case .chatgpt: return tr("用 ChatGPT 账号登录（和 Minis 相同的 Codex 登录），直接用 Plus / Pro / Team 订阅额度，不需要 API Key，Team 工作区也不用管理员批准。", "Sign in with your ChatGPT account (the same Codex sign-in Minis uses) and use your Plus / Pro / Team plan — no API key, no admin approval.")
        case .openai: return tr("API Key，按量计费。DeepSeek、通义、Kimi、智谱、中转服务都可以。", "API key, pay as you go. Works with DeepSeek, Qwen, Kimi, relays…")
        case .anthropic: return tr("Claude 的 API Key，按量计费。", "Claude API key, pay as you go.")
        case .apple: return tr("iPhone 上的 Apple 智能模型，免费、离线、不上传邮件。需要 iOS 26 和支持 Apple 智能的机型。", "Apple Intelligence model on your iPhone: free, offline, private. Needs iOS 26 on a supported device.")
        case .handoff: return tr("在 ChatGPT / Claude 等官方 App 里用你的订阅生成，回答再粘贴回来。不需要 API Key。", "Generates in the official ChatGPT / Claude app with your subscription, then pastes the answer back. No API key.")
        }
    }

    var needsKey: Bool { self == .openai || self == .anthropic }
}

/// 用订阅时打开哪个官方 App。网址是官方的“通用链接”，装了 App 就会直接在 App 里打开。
enum AIHandoffApp: String, Codable, CaseIterable, Identifiable {
    case chatgpt, claude, gemini, deepseek, doubao, kimi
    var id: String { rawValue }

    var name: String {
        switch self {
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .deepseek: return "DeepSeek"
        case .doubao: return tr("豆包", "Doubao")
        case .kimi: return "Kimi"
        }
    }

    /// 能通过网址带上提示词的 App
    func url(prompt: String) -> URL? {
        let q = prompt.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? ""
        let short = prompt.count <= 1800
        switch self {
        case .chatgpt: return URL(string: short ? "https://chatgpt.com/?q=" + q : "https://chatgpt.com/")
        case .claude: return URL(string: short ? "https://claude.ai/new?q=" + q : "https://claude.ai/new")
        case .gemini: return URL(string: "https://gemini.google.com/app")
        case .deepseek: return URL(string: "https://chat.deepseek.com/")
        case .doubao: return URL(string: "https://www.doubao.com/chat/")
        case .kimi: return URL(string: "https://www.kimi.com/")
        }
    }

    var prefills: Bool { self == .chatgpt || self == .claude }
}

struct AIConfig: Codable, Equatable {
    var provider: AIProvider = .openai
    var baseURL = ""
    var model = ""
    /// 用订阅时打开的 App（新字段必须可选，旧设置才能正常读出）
    var handoffApp: AIHandoffApp?
    /// ChatGPT 订阅登录时用的模型
    var chatgptModel: String?

    var app: AIHandoffApp { handoffApp ?? .chatgpt }

    /// 设置页上显示的一行
    var summary: String {
        switch provider {
        case .openai, .anthropic: return model
        case .chatgpt: return "ChatGPT" + ((chatgptModel?.isEmpty == false) ? " · " + chatgptModel! : "")
        case .apple: return provider.label
        case .handoff: return app.name + tr("（订阅）", " (subscription)")
        }
    }

    private static let key = "ai.config.v1"
    private static let secretKey = "ai.apikey"

    static func load() -> AIConfig {
        guard let d = UserDefaults.standard.data(forKey: key),
              let c = try? JSONDecoder().decode(AIConfig.self, from: d) else { return AIConfig() }
        return c
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(d, forKey: Self.key)
        }
    }

    static var apiKey: String {
        get { Keychain.get(secretKey) ?? "" }
        set {
            if newValue.isEmpty { Keychain.delete(secretKey) } else { Keychain.set(newValue, for: secretKey) }
        }
    }

    static var isConfigured: Bool {
        let c = load()
        switch c.provider {
        case .openai, .anthropic: return !c.baseURL.isEmpty && !c.model.isEmpty && !apiKey.isEmpty
        case .apple: return AppleAI.availability == nil
        case .handoff: return true
        case .chatgpt: return ChatGPTAuth.hasStoredCredentials
        }
    }
}

struct AIPreset: Identifiable {
    let name: String
    let provider: AIProvider
    let baseURL: String
    let model: String
    var id: String { name }

    static let all: [AIPreset] = [
        AIPreset(name: "OpenAI", provider: .openai, baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini"),
        AIPreset(name: "Anthropic Claude", provider: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-sonnet-5-5"),
        AIPreset(name: "DeepSeek", provider: .openai, baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
        AIPreset(name: tr("通义千问", "Qwen (DashScope)"), provider: .openai, baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", model: "qwen-plus"),
        AIPreset(name: "Kimi (Moonshot)", provider: .openai, baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-32k"),
        AIPreset(name: tr("智谱 GLM", "Zhipu GLM"), provider: .openai, baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4-plus"),
        AIPreset(name: "OpenRouter", provider: .openai, baseURL: "https://openrouter.ai/api/v1", model: ""),
    ]
}

// MARK: - 请求

enum AIError: LocalizedError {
    case notConfigured
    case badURL
    case http(Int, String)
    case empty
    case cancelled
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return tr("还没有设置 AI。请到“控制面板 → AI 助手”填写服务地址、模型和 API Key。",
                      "AI is not set up. Go to Control Panel → AI Assistant and enter the endpoint, model and API key.")
        case .badURL:
            return tr("服务地址格式不正确。", "The endpoint URL is invalid.")
        case .http(let code, let msg):
            return "HTTP \(code)：\(msg)"
        case .empty:
            return tr("AI 没有返回内容。", "The AI returned no content.")
        case .cancelled:
            return tr("已取消。", "Cancelled.")
        case .unavailable(let why):
            return why
        }
    }
}

enum AIClient {
    static func complete(system: String, user: String, maxTokens: Int = 2000,
                         config: AIConfig = AIConfig.load(), key: String = AIConfig.apiKey) async throws -> String {
        switch config.provider {
        case .apple:
            return try clean(try await AppleAI.complete(system: system, user: user))
        case .handoff:
            return try clean(try await AIHandoff.shared.run(system: system, user: user, app: config.app))
        case .chatgpt:
            return try clean(try await ChatGPTAuth.shared.complete(system: system, user: user, model: config.chatgptModel))
        case .openai, .anthropic:
            break
        }
        guard !key.isEmpty, !config.baseURL.isEmpty, !config.model.isEmpty else { throw AIError.notConfigured }
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }

        let urlString: String
        var body: [String: Any]
        switch config.provider {
        case .openai, .apple, .handoff, .chatgpt:
            urlString = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
            body = [
                "model": config.model,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
                "stream": false,
            ]
        case .anthropic:
            if base.hasSuffix("/v1/messages") {
                urlString = base
            } else if base.hasSuffix("/v1") {
                urlString = base + "/messages"
            } else {
                urlString = base + "/v1/messages"
            }
            body = [
                "model": config.model,
                "max_tokens": maxTokens,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ]
        }
        guard let url = URL(string: urlString) else { throw AIError.badURL }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch config.provider {
        case .openai, .apple, .handoff, .chatgpt:
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(code) else {
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? (json?["error"] as? String)
                ?? (json?["message"] as? String)
                ?? String(decoding: data.prefix(400), as: UTF8.self)
            throw AIError.http(code, msg)
        }

        var text = ""
        switch config.provider {
        case .openai, .apple, .handoff, .chatgpt:
            if let choices = json?["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any] {
                if let s = msg["content"] as? String {
                    text = s
                } else if let parts = msg["content"] as? [[String: Any]] {
                    text = parts.compactMap { $0["text"] as? String }.joined()
                }
            }
        case .anthropic:
            if let parts = json?["content"] as? [[String: Any]] {
                text = parts.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
            }
        }
        return try clean(text)
    }

    /// 去掉思考过程、代码块包裹等。
    static func clean(_ raw: String) throws -> String {
        var text = raw.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "^```[a-zA-Z]*\\n?|\\n?```$", with: "", options: .regularExpression)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AIError.empty }
        return text
    }
}

// MARK: - 提示词

enum AITone: String, CaseIterable, Identifiable {
    case formal, friendly, concise, confident, apologetic
    var id: String { rawValue }

    var label: String {
        switch self {
        case .formal: return tr("正式", "Formal")
        case .friendly: return tr("友好", "Friendly")
        case .concise: return tr("简洁", "Concise")
        case .confident: return tr("坚定", "Confident")
        case .apologetic: return tr("致歉", "Apologetic")
        }
    }

    var english: String {
        switch self {
        case .formal: return "formal and professional"
        case .friendly: return "warm, friendly but professional"
        case .concise: return "brief and to the point"
        case .confident: return "confident and assertive, but polite"
        case .apologetic: return "sincere and apologetic, taking responsibility"
        }
    }
}

enum AILang: String, CaseIterable, Identifiable {
    case auto, zh, en
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return tr("自动", "Auto")
        case .zh: return "中文"
        case .en: return "English"
        }
    }

    var instruction: String {
        switch self {
        case .auto: return "Write in the same language as the user's instructions; if none, use the language of the original email."
        case .zh: return "Write in Simplified Chinese."
        case .en: return "Write in English."
        }
    }
}

enum AIAction: String, CaseIterable, Identifiable {
    case draft, reply, polish, formal, shorter, longer, grammar, toEnglish, toChinese, subject
    var id: String { rawValue }

    var label: String {
        switch self {
        case .draft: return tr("按要求撰写", "Write")
        case .reply: return tr("写回复", "Draft Reply")
        case .polish: return tr("润色", "Polish")
        case .formal: return tr("更正式", "More Formal")
        case .shorter: return tr("更简洁", "Shorter")
        case .longer: return tr("扩写", "Longer")
        case .grammar: return tr("纠正语法", "Fix Grammar")
        case .toEnglish: return tr("译成英文", "To English")
        case .toChinese: return tr("译成中文", "To Chinese")
        case .subject: return tr("生成主题", "Subject Line")
        }
    }

    var usesSource: Bool {
        switch self {
        case .draft, .reply: return false
        default: return true
        }
    }
}

enum AIPrompts {
    static func system(tone: AITone, lang: AILang) -> String {
        """
        You are an expert assistant that writes and edits professional emails.
        Tone: \(tone.english). \(lang.instruction)
        Output ONLY the requested text. No subject line unless asked, no explanations, no markdown headings, no code fences, no surrounding quotes.
        Separate paragraphs with a blank line. Use "- " bullets only when a list genuinely helps.
        Do not invent facts, names, numbers or dates that were not provided; use placeholders like [日期] or [date] if needed.
        """
    }

    static func user(action: AIAction, instructions: String, source: String, context: String, senderName: String) -> String {
        let ins = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let sig = senderName.isEmpty ? "" : "\nThe sender's name is \(senderName)."
        switch action {
        case .draft:
            return "Write an email based on these instructions:\n\(ins.isEmpty ? "(no instructions given; write a sensible short email)" : ins)\(sig)"
                + (context.isEmpty ? "" : "\n\nEarlier emails for context:\n\(context)")
        case .reply:
            return "Write a reply to the most recent email in the thread below.\(sig)\nAdditional instructions: \(ins.isEmpty ? "none" : ins)\n\nThread:\n\(context)"
        case .polish:
            return "Improve the clarity, flow and wording of this text while keeping its meaning and language:\n\n\(source)"
        case .formal:
            return "Rewrite this text in a more formal, professional register, same language:\n\n\(source)"
        case .shorter:
            return "Rewrite this text to be noticeably more concise, keeping all key information, same language:\n\n\(source)"
        case .longer:
            return "Expand this text with appropriate detail and courtesy, same language:\n\n\(source)"
        case .grammar:
            return "Correct grammar, spelling and punctuation in this text. Change nothing else:\n\n\(source)"
        case .toEnglish:
            return "Translate this email text into natural, professional English:\n\n\(source)"
        case .toChinese:
            return "将以下邮件内容翻译成自然、专业的简体中文：\n\n\(source)"
        case .subject:
            return "Write one short, specific subject line for this email. Output only the subject line, without quotes or a 'Subject:' prefix.\n\n\(source)"
        }
    }
}

/// 把 AI 返回的纯文本转成编辑器 HTML（段落、列表、**粗体**）。
enum AIText {
    static func toHTML(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out = ""
        var list: String?
        var lastBlank = false
        func close() {
            if let l = list {
                out += "</\(l)>"
                list = nil
            }
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                close()
                if !lastBlank { out += "<div><br></div>" }
                lastBlank = true
                continue
            }
            lastBlank = false
            if let r = line.range(of: "^([-*•·]|\\d{1,2}[.)、])\\s+", options: .regularExpression) {
                let ordered = line[r].first?.isNumber ?? false
                let tag = ordered ? "ol" : "ul"
                if list != tag {
                    close()
                    out += "<\(tag)>"
                    list = tag
                }
                out += "<li>\(inline(String(line[r.upperBound...])))</li>"
                continue
            }
            close()
            out += "<div>\(inline(line))</div>"
        }
        close()
        return out
    }

    private static func inline(_ s: String) -> String {
        HTMLText.escape(s).replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<b>$1</b>", options: .regularExpression)
    }
}

// MARK: - 写作面板

struct AIWriterSheet: View {
    @ObservedObject var ed: EditorController
    let context: String
    let onSubject: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var instructions = ""
    @State private var tone: AITone = .formal
    @State private var lang: AILang = .auto
    @State private var busy = false
    @State private var result = ""
    @State private var lastAction: AIAction?
    @State private var usedSelection = false
    @State private var error: String?

    var body: some View {
        RetroPanel(tr("AI 写作助手", "AI Writing Assistant")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !AIConfig.isConfigured {
                        Text(AIError.notConfigured.localizedDescription)
                            .font(RT.font(12))
                            .padding(10)
                            .overlay(Rectangle().stroke(Color.ink, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    }
                    RetroGroup(tr("要求（撰写 / 写回复时使用）", "Instructions (for Write / Reply)")) {
                        TextEditor(text: $instructions)
                            .font(RT.font(13))
                            .scrollContentBackground(.hidden)
                            .frame(height: 80)
                            .overlay(alignment: .topLeading) {
                                if instructions.isEmpty {
                                    Text(tr("例如：告知客户 A 项目延期一周，并道歉、给出新的交付日期", "e.g. Tell the client project A slips one week, apologise, give the new date"))
                                        .font(RT.font(12))
                                        .opacity(0.45)
                                        .padding(.top, 8)
                                        .padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                    RetroRadio(label: tr("语气", "Tone"), options: AITone.allCases.map { ($0, $0.label) }, selection: $tone, labelWidth: 44)
                    RetroRadio(label: tr("语言", "Lang"), options: AILang.allCases.map { ($0, $0.label) }, selection: $lang, labelWidth: 44)
                    Text(tr("修改类操作作用于选中的文字；没有选中时作用于正文（不含引用的原邮件）。",
                            "Edit actions apply to the selected text, or to the body (excluding quoted mail) if nothing is selected."))
                        .font(RT.font(10))
                        .opacity(0.7)
                    FlowRow(spacing: 10) {
                        ForEach(AIAction.allCases) { a in
                            if a != .reply || !context.isEmpty {
                                Button(a.label) { run(a) }
                                    .buttonStyle(RetroButtonStyle(isDefault: a == .draft || a == .reply, compact: true))
                                    .disabled(busy)
                            }
                        }
                        if ed.canShowWritingTools {
                            Button(tr("Apple 写作工具…", "Apple Writing Tools…")) {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ed.showWritingTools() }
                            }
                            .buttonStyle(RetroButtonStyle(compact: true))
                        }
                    }
                    .padding(.vertical, 4)
                    if busy {
                        RetroBusy(text: tr("AI 正在思考…", "Thinking…"))
                    }
                    AIHandoffBanner()
                    if !result.isEmpty {
                        RetroGroup(tr("结果", "Result")) {
                            Text(result)
                                .font(RT.font(13))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        resultActions
                    }
                    Text(tr("邮件内容会发送到你设置的 AI 服务商进行处理。", "Email content is sent to the AI provider you configured."))
                        .font(RT.font(10))
                        .opacity(0.6)
                }
                .padding(14)
            }
        }
        .retroAlert($error)
        .presentationDetents([.large])
        .onDisappear { AIHandoff.shared.cancel() }
    }

    @ViewBuilder
    private var resultActions: some View {
        FlowRow(spacing: 10) {
            if lastAction == .subject {
                Button(tr("用作主题", "Use as Subject")) {
                    onSubject(result.replacingOccurrences(of: "\n", with: " "))
                    dismiss()
                }
                .buttonStyle(RetroButtonStyle(isDefault: true, compact: true))
            } else {
                if usedSelection {
                    Button(tr("替换选中文字", "Replace Selection")) {
                        ed.act("replaceSelection", AIText.toHTML(result))
                        dismiss()
                    }
                    .buttonStyle(RetroButtonStyle(isDefault: true, compact: true))
                }
                Button(tr("替换正文", "Replace Body")) {
                    ed.act("replaceBody", AIText.toHTML(result))
                    dismiss()
                }
                .buttonStyle(RetroButtonStyle(isDefault: !usedSelection, compact: true))
                Button(tr("插入到光标处", "Insert at Cursor")) {
                    ed.act("insertHTML", AIText.toHTML(result))
                    dismiss()
                }
                .buttonStyle(RetroButtonStyle(compact: true))
            }
            Button(tr("复制", "Copy")) { UIPasteboard.general.string = result }
                .buttonStyle(RetroButtonStyle(compact: true))
            if let a = lastAction {
                Button(tr("重新生成", "Retry")) { run(a) }
                    .buttonStyle(RetroButtonStyle(compact: true))
            }
        }
    }

    private func run(_ action: AIAction) {
        busy = true
        lastAction = action
        Task {
            defer { busy = false }
            var source = ""
            usedSelection = false
            if action.usesSource {
                let selected = await ed.selectedText().trimmingCharacters(in: .whitespacesAndNewlines)
                if !selected.isEmpty && action != .subject {
                    source = selected
                    usedSelection = true
                } else {
                    source = await ed.bodyText()
                }
                if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    error = tr("正文还是空的，先写点内容或用“按要求撰写”。", "The body is empty. Write something first, or use Write.")
                    return
                }
            }
            let sender = AccountStore.shared.accounts.first?.name ?? ""
            let effectiveLang: AILang = action == .toEnglish ? .en : action == .toChinese ? .zh : lang
            do {
                result = try await AIClient.complete(
                    system: AIPrompts.system(tone: tone, lang: effectiveLang),
                    user: AIPrompts.user(action: action, instructions: instructions, source: String(source.prefix(12000)),
                                         context: context, senderName: sender))
            } catch AIError.cancelled {
                // 用户取消
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - 会话总结

struct AISummarySheet: View {
    let threadText: String
    let onDraftReply: (String) -> Void

    @State private var summary = ""
    @State private var busy = false
    @State private var error: String?
    @State private var replyInstructions = ""

    var body: some View {
        RetroPanel(tr("AI 会话总结", "AI Thread Recap")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if busy {
                        RetroBusy(text: tr("AI 正在阅读邮件…", "Reading the thread…"))
                    }
                    AIHandoffBanner()
                    if !summary.isEmpty {
                        RetroGroup(tr("总结", "Summary")) {
                            Text(summary)
                                .font(RT.font(13))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 10) {
                            Button(tr("重新总结", "Again")) { summarize() }
                                .buttonStyle(RetroButtonStyle(compact: true))
                            Button(tr("复制", "Copy")) { UIPasteboard.general.string = summary }
                                .buttonStyle(RetroButtonStyle(compact: true))
                        }
                    }
                    RetroGroup(tr("用 AI 起草回复", "Draft a reply with AI")) {
                        RetroField(label: "", text: $replyInstructions, placeholder: tr("回复要点（可留空）", "Key points (optional)"))
                        HStack {
                            Spacer()
                            Button(tr("起草并打开", "Draft & Open")) { draftReply() }
                                .buttonStyle(RetroButtonStyle(isDefault: true, compact: true))
                                .disabled(busy)
                        }
                    }
                }
                .padding(14)
            }
        }
        .retroAlert($error)
        .retroSheetStyle()
        .task { if summary.isEmpty { summarize() } }
        .onDisappear { AIHandoff.shared.cancel() }
    }

    private var langLine: String {
        tr("Write the summary in Simplified Chinese.", "Write the summary in English.")
    }

    private func summarize() {
        busy = true
        Task {
            defer { busy = false }
            do {
                summary = try await AIClient.complete(
                    system: "You summarize email threads for a busy professional. Be accurate and specific; never invent details. \(langLine) Plain text only, no markdown headings.",
                    user: """
                    Summarize this email thread using these sections (omit any that are empty):
                    \(tr("概要", "Overview")): 1–2 sentences
                    \(tr("要点", "Key points")): bullets starting with "- "
                    \(tr("已定事项", "Decisions")): bullets
                    \(tr("待办（谁 / 做什么 / 何时）", "Action items (who / what / when)")): bullets
                    \(tr("待确认问题", "Open questions")): bullets

                    Thread:
                    \(threadText)
                    """)
            } catch AIError.cancelled {
                // 用户取消
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func draftReply() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let sender = AccountStore.shared.accounts.first?.name ?? ""
                let text = try await AIClient.complete(
                    system: AIPrompts.system(tone: .formal, lang: .auto),
                    user: AIPrompts.user(action: .reply, instructions: replyInstructions, source: "", context: threadText, senderName: sender))
                onDraftReply(text)
            } catch AIError.cancelled {
                // 用户取消
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - 设置面板

struct AISettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config = AIConfig.load()
    @State private var key = AIConfig.apiKey
    @State private var testing = false
    @State private var message: String?

    var body: some View {
        RetroPanel(tr("AI 助手", "AI Assistant")) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    RetroGroup(tr("用什么来生成", "Where AI runs")) {
                        ForEach(AIProvider.allCases) { p in
                            Button { config.provider = p } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    ZStack {
                                        Circle().stroke(config.provider == p ? IOS3.dateBlue : IOS3.chevron, lineWidth: 2)
                                        if config.provider == p { Circle().fill(IOS3.dateBlue).padding(5) }
                                    }
                                    .frame(width: 20, height: 20)
                                    .padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.label).font(RT.font(15, .bold))
                                        Text(p.detail).font(RT.font(12)).foregroundColor(IOS3.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    switch config.provider {
                    case .openai, .anthropic: apiGroup
                    case .apple: appleGroup
                    case .handoff: handoffGroup
                    case .chatgpt: chatgptGroup
                    }
                    HStack(spacing: 12) {
                        Spacer()
                        if config.provider != .handoff {
                            Button(tr("测试", "Test")) { test() }
                                .buttonStyle(RetroButtonStyle())
                        }
                        Button(tr("存储", "Save")) {
                            save()
                            dismiss()
                        }
                        .buttonStyle(RetroButtonStyle(isDefault: true))
                    }
                    .padding(.top, 8)
                }
                .padding(14)
            }
        }
        .busyOverlay(testing, tr("正在测试…", "Testing…"))
        .retroAlert($message)
        .presentationDetents([.large])
    }

    private var apiGroup: some View {
        RetroGroup(tr("服务", "Service")) {
            HStack {
                Spacer().frame(width: 86)
                Menu {
                    ForEach(AIPreset.all) { p in
                        Button(p.name) {
                            config.provider = p.provider
                            config.baseURL = p.baseURL
                            if !p.model.isEmpty { config.model = p.model }
                        }
                    }
                } label: {
                    Text(tr("套用常见服务 ▾", "Presets ▾")).font(RT.font(12, .bold))
                }
            }
            RetroField(label: tr("服务地址", "Base URL"), text: $config.baseURL, placeholder: "https://api.example.com/v1", keyboard: .URL)
            RetroField(label: tr("模型", "Model"), text: $config.model, placeholder: tr("服务商文档中的模型名", "Model name from provider docs"))
            RetroField(label: "API Key", text: $key, placeholder: "sk-…", secure: true)
            Text(tr("国内中转服务（OpenAI 兼容格式）也可以用：选“OpenAI 兼容”，填中转地址和 Key 即可。模型名以服务商文档为准。",
                    "Relay services with an OpenAI-compatible API work too: choose OpenAI-compatible and enter the relay URL and key. Check model names in your provider's docs."))
                .font(RT.font(10))
                .opacity(0.7)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chatgptGroup: some View {
        ChatGPTSignInGroup(model: Binding(get: { config.chatgptModel ?? "" }, set: { config.chatgptModel = $0 }))
    }

    private var appleGroup: some View {
        RetroGroup(tr("Apple 本机 AI", "Apple On-Device AI")) {
            Text(AppleAI.availability ?? tr("✓ 这台 iPhone 可以使用。邮件内容只在手机上处理。", "✓ Available on this iPhone. Mail is processed on the device only."))
                .font(RT.font(13))
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
            Text(tr("本机模型比较小，适合润色、改语气、总结、短回复；长文写作和翻译质量不如云端大模型。",
                    "The on-device model is small: great for polishing, tone, recaps and short replies; long writing and translation are better with a cloud model."))
                .font(RT.font(11))
                .opacity(0.75)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }

    private var handoffGroup: some View {
        RetroGroup(tr("用哪个 App", "Which app")) {
            IOS3Segmented(options: [AIHandoffApp.chatgpt, .claude, .gemini].map { ($0, $0.name) },
                          selection: Binding(get: { config.app }, set: { config.handoffApp = $0 }))
                .padding(.horizontal, 12)
                .padding(.top, 10)
            IOS3Segmented(options: [AIHandoffApp.deepseek, .doubao, .kimi].map { ($0, $0.name) },
                          selection: Binding(get: { config.app }, set: { config.handoffApp = $0 }))
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            Text(tr("""
            用法：点 AI 功能后会自动打开 \(config.app.name)，提示词已经填好（或已复制，粘贴即可）。它回答完后，复制回答，回到 RetroMail 点“粘贴回答”，结果就会放进邮件里。

            这样用的是你在官方 App 里登录的订阅。ChatGPT 可以直接选上面的“ChatGPT 订阅（账号登录）”，更方便；Claude、Gemini 等的订阅不开放给第三方应用登录，就用这种方式。
            """, """
            How it works: tapping an AI action opens \(config.app.name) with the prompt filled in (or copied — just paste). When it answers, copy the reply, return to RetroMail and tap Paste Answer.

            This uses the subscription you're signed into in the official app. For ChatGPT, the “ChatGPT Subscription (Sign In)” option above is easier; Claude, Gemini and others don't offer subscription sign-in to third-party apps, so use this instead.
            """))
                .font(RT.font(12))
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
            Text(tr("另外：iOS 18.2 以上、开启 Apple 智能并在设置里登录了 ChatGPT 的话，写信时选中文字 → “写作工具”，也能直接用你的 ChatGPT 账号改写和撰写。",
                    "Also: on iOS 18.2+ with Apple Intelligence and ChatGPT signed in under Settings, select text while writing → Writing Tools to rewrite or compose with your ChatGPT account."))
                .font(RT.font(11))
                .opacity(0.75)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }

    private func save() {
        config.baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config.model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        config.save()
        AIConfig.apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func test() {
        testing = true
        let c = config
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { testing = false }
            do {
                let r = try await AIClient.complete(system: "Reply with exactly: OK", user: "ping", maxTokens: 20, config: c, key: k)
                message = tr("✓ 连接成功，AI 回复：", "✓ Connected. AI replied: ") + String(r.prefix(80))
            } catch {
                message = "✗ " + error.localizedDescription
            }
        }
    }
}
