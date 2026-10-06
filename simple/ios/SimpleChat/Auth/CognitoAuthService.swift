import Foundation

struct CognitoTokens: Sendable {
    let accessToken: String
    let idToken: String
    let refreshToken: String?
    let expiresAt: Date
}

enum CognitoAuthError: LocalizedError {
    case invalidResponse
    case challengeRequired(String)
    case apiError(String)
    case missingToken

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Cognito からの応答を解析できませんでした。"
        case .challengeRequired(let name):
            return "追加の認証チャレンジが必要です: \(name)"
        case .apiError(let message):
            return message
        case .missingToken:
            return "アクセストークンを取得できませんでした。"
        }
    }
}

actor CognitoAuthService {
    private let region: String
    private let clientId: String

    init(region: String = AppConfig.awsRegion, clientId: String = AppConfig.userPoolClientId) {
        self.region = region
        self.clientId = clientId
    }

    func signIn(username: String, password: String) async throws -> CognitoTokens {
        let endpoint = URL(string: "https://cognito-idp.\(region).amazonaws.com/")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSCognitoIdentityProviderService.InitiateAuth", forHTTPHeaderField: "X-Amz-Target")

        let body: [String: Any] = [
            "AuthFlow": "USER_PASSWORD_AUTH",
            "ClientId": clientId,
            "AuthParameters": [
                "USERNAME": username,
                "PASSWORD": password,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CognitoAuthError.invalidResponse
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        if http.statusCode >= 400 {
            let message = (json["message"] as? String)
                ?? (json["__type"] as? String)
                ?? "認証に失敗しました (HTTP \(http.statusCode))"
            throw CognitoAuthError.apiError(message)
        }

        if let challenge = json["ChallengeName"] as? String {
            throw CognitoAuthError.challengeRequired(challenge)
        }

        guard
            let result = json["AuthenticationResult"] as? [String: Any],
            let accessToken = result["AccessToken"] as? String,
            let idToken = result["IdToken"] as? String
        else {
            throw CognitoAuthError.missingToken
        }

        let expiresIn = result["ExpiresIn"] as? Double ?? 3600
        return CognitoTokens(
            accessToken: accessToken,
            idToken: idToken,
            refreshToken: result["RefreshToken"] as? String,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }
}
