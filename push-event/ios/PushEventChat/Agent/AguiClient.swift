import Foundation

enum AguiClientError: LocalizedError {
    case invalidURL
    case httpError(Int, String)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Agent Runtime の URL が不正です。"
        case .httpError(let code, let body):
            return "HTTP \(code): \(body)"
        case .decodingError(let message):
            return message
        }
    }
}

actor AguiClient {
    private let region: String
    private let agentRuntimeArn: String

    init(
        region: String = AppConfig.awsRegion,
        agentRuntimeArn: String = AppConfig.agentRuntimeArn
    ) {
        self.region = region
        self.agentRuntimeArn = agentRuntimeArn
    }

    func stream(
        messages: [ChatMessage],
        threadId: String,
        sessionId: String,
        accessToken: String,
        forwardedProps: [String: String] = [:]
    ) -> AsyncThrowingStream<AguiEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.performStream(
                        messages: messages,
                        threadId: threadId,
                        sessionId: sessionId,
                        accessToken: accessToken,
                        forwardedProps: forwardedProps,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func performStream(
        messages: [ChatMessage],
        threadId: String,
        sessionId: String,
        accessToken: String,
        forwardedProps: [String: String],
        continuation: AsyncThrowingStream<AguiEvent, Error>.Continuation
    ) async throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        let escapedArn = agentRuntimeArn.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? agentRuntimeArn
        guard let url = URL(
            string: "https://bedrock-agentcore.\(region).amazonaws.com/runtimes/\(escapedArn)/invocations?qualifier=DEFAULT"
        ) else {
            throw AguiClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(sessionId, forHTTPHeaderField: "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id")
        request.timeoutInterval = 300

        let payload = RunAgentInput(
            threadId: threadId,
            runId: UUID().uuidString,
            messages: messages.map {
                AguiMessage(id: $0.id, role: $0.role.rawValue, content: $0.content)
            },
            state: [:],
            tools: [],
            context: [],
            forwardedProps: forwardedProps
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AguiClientError.invalidURL
        }

        if http.statusCode >= 400 {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 2_000 {
                    break
                }
            }
            throw AguiClientError.httpError(http.statusCode, body)
        }

        for try await rawLine in bytes.lines {
            if Task.isCancelled {
                break
            }

            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix(":") {
                continue
            }

            let payload: String
            if line.hasPrefix("data:") {
                payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("{") {
                payload = line
            } else {
                continue
            }

            if let event = Self.parseSSEEvent(payload) {
                continuation.yield(event)
            }
        }
    }

    private static func parseSSEEvent(_ data: String) -> AguiEvent? {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let jsonData = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let type = object["type"] as? String
        else {
            return nil
        }

        return AguiEvent(
            type: type,
            delta: object["delta"] as? String,
            message: object["message"] as? String,
            code: object["code"] as? String,
            messageId: object["messageId"] as? String
        )
    }
}
