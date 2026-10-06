import SwiftUI

struct LoginView: View {
    @Binding var accessToken: String?

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var focusedField: Field?

    private let authService = CognitoAuthService()

    private enum Field: Hashable {
        case username
        case password
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Cognito サインイン")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("ユーザー名")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ChatInputField(
                            text: $username,
                            placeholder: "demo",
                            isFocused: focusedField == .username,
                            keyboardType: .asciiCapable,
                            returnKeyType: .next,
                            autocapitalizationType: .none,
                            onSubmit: { focusedField = .password },
                            onFocusChange: { focused in
                                if focused {
                                    focusedField = .username
                                } else if focusedField == .username {
                                    focusedField = nil
                                }
                            }
                        )
                        .frame(height: 40)

                        Text("パスワード")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ChatInputField(
                            text: $password,
                            placeholder: "パスワード",
                            isFocused: focusedField == .password,
                            isSecure: true,
                            keyboardType: .asciiCapable,
                            returnKeyType: .go,
                            autocapitalizationType: .none,
                            onSubmit: {
                                focusedField = nil
                                Task { await signIn() }
                            },
                            onFocusChange: { focused in
                                if focused {
                                    focusedField = .password
                                } else if focusedField == .password {
                                    focusedField = nil
                                }
                            }
                        )
                        .frame(height: 40)
                    }

                    Text(configurationFooter)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button {
                        focusedField = nil
                        Task { await signIn() }
                    } label: {
                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("サインイン")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || username.isEmpty || password.isEmpty || !AppConfig.isConfigured)
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Push Event Chat")
        }
    }

    private var configurationFooter: String {
        var lines = [String]()
        if AppConfig.isConfigured {
            lines.append("リージョン: \(AppConfig.awsRegion)")
        } else {
            lines.append("Config.swift に CDK の出力値を設定してください。")
        }
        lines.append("ユーザー名とパスワードは Cognito で作成したデモユーザーを入力してください。")
        lines.append("シミュレータでキーボードが出ないときは、I/O → Keyboard → Connect Hardware Keyboard をオフにするか、Mac キーボードで入力します。")
        return lines.joined(separator: "\n")
    }

    private func signIn() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let tokens = try await authService.signIn(username: username, password: password)
            KeychainStore.save(tokens: tokens, username: username)
            accessToken = tokens.accessToken
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
