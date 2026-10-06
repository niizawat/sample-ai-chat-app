import SwiftUI

struct LoginView: View {
    @Binding var accessToken: String?

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private let authService = CognitoAuthService()

    private enum Field: Hashable {
        case username
        case password
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ユーザー名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.next)
                        .focused($focusedField, equals: .username)
                        .onSubmit { focusedField = .password }

                    // SecureField / textContentType はシミュレータで AutoFill と干渉しやすい。
                    Group {
                        #if targetEnvironment(simulator)
                        TextField("パスワード", text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                        #else
                        SecureField("パスワード", text: $password)
                            .textContentType(.password)
                        #endif
                    }
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit {
                        Task { await signIn() }
                    }
                } header: {
                    Text("Cognito サインイン")
                } footer: {
                    Text(configurationFooter)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
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
                    .disabled(isLoading || username.isEmpty || password.isEmpty || !AppConfig.isConfigured)
                }
            }
            .navigationTitle("Agent Chat")
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                focusedField = .username
            }
        }
    }

    private var configurationFooter: String {
        if AppConfig.isConfigured {
            return "リージョン: \(AppConfig.awsRegion)"
        }
        return "Config.swift に CDK の出力値を設定してください。"
    }

    private func signIn() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let tokens = try await authService.signIn(username: username, password: password)
            accessToken = tokens.accessToken
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
