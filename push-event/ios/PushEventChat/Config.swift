import Foundation

/// Values from `cdk deploy` stack outputs. Replace placeholders after deploy.
enum AppConfig {
    static let awsRegion = "us-east-1"
    static let userPoolId = "REPLACE_USER_POOL_ID"
    static let userPoolClientId = "REPLACE_USER_POOL_CLIENT_ID"
    static let agentRuntimeArn = "REPLACE_AGENT_RUNTIME_ARN"
    /// API Gateway base URL ending with `/`
    static let devicesApiUrl = "REPLACE_DEVICES_API_URL"

    static var isConfigured: Bool {
        !userPoolId.hasPrefix("REPLACE_")
            && !userPoolClientId.hasPrefix("REPLACE_")
            && !agentRuntimeArn.hasPrefix("REPLACE_")
            && !devicesApiUrl.hasPrefix("REPLACE_")
    }

    static var hasFirebasePlist: Bool {
        Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil
    }
}
