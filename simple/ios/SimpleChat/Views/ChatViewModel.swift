import Foundation
import Observation

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var inputText = ""
    var isSending = false
    var errorMessage: String?

    private let accessToken: String
    private let client = AguiClient()
    private let threadId = UUID().uuidString
    private let sessionId: String

    init(accessToken: String) {
        self.accessToken = accessToken
        // AgentCore requires session IDs of 33+ characters.
        self.sessionId = "session-\(UUID().uuidString)"
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

        do {
            let eventStream = await client.stream(
                messages: history,
                threadId: threadId,
                sessionId: sessionId,
                accessToken: accessToken
            )

            for try await event in eventStream {
                switch event.type {
                case AguiEventType.textMessageContent.rawValue:
                    if let delta = event.delta,
                       let index = messages.firstIndex(where: { $0.id == assistantId }) {
                        messages[index].content += delta
                    }
                case AguiEventType.runError.rawValue:
                    let detail = [event.code, event.message]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " - ")
                    errorMessage = detail.isEmpty ? "エージェント実行中にエラーが発生しました。" : detail
                    if let index = messages.firstIndex(where: { $0.id == assistantId }),
                       messages[index].content.isEmpty {
                        messages[index].content = errorMessage ?? "エラーが発生しました。"
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

        isSending = false
    }
}
