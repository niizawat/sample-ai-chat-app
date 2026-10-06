import Foundation

/// Values from `cdk deploy` stack outputs. Replace placeholders after deploy.
enum AppConfig {
    static let awsRegion = "us-east-1"
    static let userPoolId = "REPLACE_USER_POOL_ID"
    static let userPoolClientId = "REPLACE_USER_POOL_CLIENT_ID"
    static let agentRuntimeArn = "REPLACE_AGENT_RUNTIME_ARN"

    static var isConfigured: Bool {
        !userPoolId.hasPrefix("REPLACE_")
            && !userPoolClientId.hasPrefix("REPLACE_")
            && !agentRuntimeArn.hasPrefix("REPLACE_")
    }
}
