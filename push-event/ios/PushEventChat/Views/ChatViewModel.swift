import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var inputText = ""
    var isSending = false
    var errorMessage: String?

    private var accessToken: String
    private let client = AguiClient()
    private let authService = CognitoAuthService()
    private var threadId = UUID().uuidString
    /// AgentCore requires session IDs of 33+ characters.
    private var sessionId = "session-\(UUID().uuidString)"
    private var handledEventIds = Set<String>()

    init(accessToken: String) {
        self.accessToken = accessToken
    }

    func updateAccessToken(_ token: String) {
        accessToken = token
    }

    func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        errorMessage = nil
        isSending = true
        inputText = ""

        let userMessage = ChatMessage(id: UUID().uuidString, role: .user, content: text)
        messages.append(userMessage)

        let assistantId = UUID().uuidString
        messages.append(ChatMessage(id: assistantId, role: .assistant, content: ""))

        let history = messages.filter { $0.id != assistantId }
        await runStream(history: history, assistantId: assistantId, forwardedProps: [:])
        isSending = false
    }

    /// Start an assistant-led turn from a push event (no user bubble).
    func startFromEvent(eventId: String?) async {
        if let eventId {
            guard !handledEventIds.contains(eventId) else { return }
            handledEventIds.insert(eventId)
        }
        guard !isSending else { return }

        errorMessage = nil
        isSending = true

        // Avoid sticky routing to a stale AgentCore container after redeploy.
        threadId = UUID().uuidString
        sessionId = "session-\(UUID().uuidString)"

        let assistantId = UUID().uuidString
        messages.append(ChatMessage(id: assistantId, role: .assistant, content: ""))

        var props: [String: String] = [:]
        if let eventId, !eventId.isEmpty {
            props["eventId"] = eventId
        } else {
            props["pullPending"] = "true"
        }

        // Event-driven turns send no prior history. The server injects a user instruction
        // so Bedrock never sees an assistant-first conversation.
        await runStream(history: [], assistantId: assistantId, forwardedProps: props)
        isSending = false
    }

    /// Simulator helper: ask the agent for the newest pending event.
    func pullPendingEvent() async {
        await startFromEvent(eventId: nil)
    }

    private func runStream(
        history: [ChatMessage],
        assistantId: String,
        forwardedProps: [String: String]
    ) async {
        do {
            let token = try await authService.validAccessToken()
            accessToken = token

            let eventStream = await client.stream(
                messages: history,
                threadId: threadId,
                sessionId: sessionId,
                accessToken: token,
                forwardedProps: forwardedProps
            )

            for try await event in eventStream {
                switch event.type {
                case AguiEventType.textMessageContent.rawValue:
                    if let delta = event.delta,
                       let index = messages.firstIndex(where: { $0.id == assistantId }) {
                        messages[index].content += delta
                    }
                case AguiEventType.runError.rawValue:
                    let rawDetail = [event.code, event.message]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " - ")
                    errorMessage = Self.userFacingError(from: rawDetail)
                    // Keep any partial assistant text; do not dump STRANDS_FORCE_STOP into the bubble.
                    if let index = messages.firstIndex(where: { $0.id == assistantId }),
                       messages[index].content.isEmpty {
                        messages[index].content = "応答を生成できませんでした。もう一度お試しください。"
                    }
                default:
                    break
                }
            }

            if let index = messages.firstIndex(where: { $0.id == assistantId }),
               messages[index].content.isEmpty {
                messages[index].content = errorMessage ?? "(応答がありませんでした)"
            }
        } catch {
            errorMessage = error.localizedDescription
            if let index = messages.firstIndex(where: { $0.id == assistantId }),
               messages[index].content.isEmpty {
                messages.remove(at: index)
            }
        }
    }

    private static func userFacingError(from detail: String) -> String {
        let lowered = detail.lowercased()
        if detail.isEmpty {
            return "エージェント実行中にエラーが発生しました。"
        }
        if lowered.contains("timed out") || lowered.contains("timeout") || lowered.contains("read timed out") {
            return "モデル応答がタイムアウトしました。もう一度お試しください。"
        }
        if lowered.contains("max_tokens") || lowered.contains("maximum token") {
            return "応答が長くなりすぎたため中断されました。短く聞き直すか、もう一度お試しください。"
        }
        if lowered.contains("must start with a user message") || lowered.contains("validationexception") {
            return "会話の開始に失敗しました。通知をもう一度開くか、サインインし直してください。"
        }
        if lowered.contains("strands_force_stop") || lowered.contains("force_stop") {
            return "エージェントの応答が中断されました。もう一度お試しください。"
        }
        // Keep short; avoid dumping long stack-style messages into the UI.
        if detail.count > 160 {
            return "エージェント実行中にエラーが発生しました。"
        }
        return detail
    }
}
