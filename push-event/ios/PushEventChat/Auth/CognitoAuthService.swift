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
    case missingRefreshToken

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
        case .missingRefreshToken:
            return "リフレッシュトークンがありません。再度サインインしてください。"
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
        let body: [String: Any] = [
            "AuthFlow": "USER_PASSWORD_AUTH",
            "ClientId": clientId,
            "AuthParameters": [
                "USERNAME": username,
                "PASSWORD": password,
            ],
        ]
        return try await initiateAuth(body: body)
    }

    func refresh(refreshToken: String) async throws -> CognitoTokens {
        let body: [String: Any] = [
            "AuthFlow": "REFRESH_TOKEN_AUTH",
            "ClientId": clientId,
            "AuthParameters": [
                "REFRESH_TOKEN": refreshToken,
            ],
        ]
        let tokens = try await initiateAuth(body: body)
        // Cognito may omit refresh token on refresh; keep the existing one.
        if tokens.refreshToken == nil {
            return CognitoTokens(
                accessToken: tokens.accessToken,
                idToken: tokens.idToken,
                refreshToken: refreshToken,
                expiresAt: tokens.expiresAt
            )
        }
        return tokens
    }

    /// Returns a valid access token, refreshing from Keychain when needed.
    func validAccessToken() async throws -> String {
        let tokens = try await validTokens()
        return tokens.accessToken
    }

    /// ID token for API Gateway Cognito authorizer (Access Token is rejected without scopes).
    func validIdToken() async throws -> String {
        let tokens = try await validTokens()
        return tokens.idToken
    }

    private func validTokens() async throws -> CognitoTokens {
        if let access = KeychainStore.get(.accessToken),
           let idToken = KeychainStore.get(.idToken),
           let expiresRaw = KeychainStore.get(.accessTokenExpiresAt),
           let expires = TimeInterval(expiresRaw),
           Date().timeIntervalSince1970 < expires - 60 {
            return CognitoTokens(
                accessToken: access,
                idToken: idToken,
                refreshToken: KeychainStore.get(.refreshToken),
                expiresAt: Date(timeIntervalSince1970: expires)
            )
        }

        guard let refreshToken = KeychainStore.get(.refreshToken) else {
            throw CognitoAuthError.missingRefreshToken
        }
        let username = KeychainStore.get(.username) ?? ""
        let tokens = try await refresh(refreshToken: refreshToken)
        KeychainStore.save(tokens: tokens, username: username)
        return tokens
    }

    private func initiateAuth(body: [String: Any]) async throws -> CognitoTokens {
        let endpoint = URL(string: "https://cognito-idp.\(region).amazonaws.com/")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue("AWSCognitoIdentityProviderService.InitiateAuth", forHTTPHeaderField: "X-Amz-Target")
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
