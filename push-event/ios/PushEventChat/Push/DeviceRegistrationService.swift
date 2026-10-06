import Foundation

enum DeviceRegistrationError: LocalizedError {
    case invalidURL
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "デバイス登録 API の URL が不正です。"
        case .httpError(let code, let body):
            return "デバイス登録に失敗しました (HTTP \(code)): \(body)"
        }
    }
}

actor DeviceRegistrationService {
    private let baseURL: String

    init(baseURL: String = AppConfig.devicesApiUrl) {
        self.baseURL = baseURL
    }

    func register(fcmToken: String, idToken: String) async throws {
        var urlString = baseURL
        if !urlString.hasSuffix("/") {
            urlString += "/"
        }
        urlString += "devices"
        guard let url = URL(string: urlString) else {
            throw DeviceRegistrationError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fcmToken": fcmToken])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DeviceRegistrationError.invalidURL
        }
        if http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DeviceRegistrationError.httpError(http.statusCode, body)
        }
    }
}
