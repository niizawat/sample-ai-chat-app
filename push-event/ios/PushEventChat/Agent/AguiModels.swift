import Foundation

struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: String
    let role: Role
    var content: String

    enum Role: String, Sendable {
        case user
        case assistant
        case system
    }
}

struct RunAgentInput: Encodable, Sendable {
    let threadId: String
    let runId: String
    let messages: [AguiMessage]
    let state: [String: String]
    let tools: [String]
    let context: [String]
    let forwardedProps: [String: String]

    enum CodingKeys: String, CodingKey {
        case threadId
        case runId
        case messages
        case state
        case tools
        case context
        case forwardedProps
    }
}

struct AguiMessage: Encodable, Sendable {
    let id: String
    let role: String
    let content: String
}

enum AguiEventType: String {
    case runStarted = "RUN_STARTED"
    case runFinished = "RUN_FINISHED"
    case runError = "RUN_ERROR"
    case textMessageStart = "TEXT_MESSAGE_START"
    case textMessageContent = "TEXT_MESSAGE_CONTENT"
    case textMessageEnd = "TEXT_MESSAGE_END"
}

struct AguiEvent: Sendable {
    let type: String
    let delta: String?
    let message: String?
    let code: String?
    let messageId: String?
}
