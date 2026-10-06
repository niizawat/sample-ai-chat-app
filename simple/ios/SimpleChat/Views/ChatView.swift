import SwiftUI

struct ChatView: View {
    @Binding var accessToken: String?
    @State private var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool

    private let quickPrompts = [
        "Reply with only OK",
        "こんにちは",
        "自己紹介して",
    ]

    init(accessToken: Binding<String?>) {
        _accessToken = accessToken
        _viewModel = State(initialValue: ChatViewModel(accessToken: accessToken.wrappedValue ?? ""))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(viewModel.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.messages) { _, newValue in
                        if let last = newValue.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onTapGesture {
                        isInputFocused = false
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickPrompts, id: \.self) { prompt in
                            Button(prompt) {
                                viewModel.inputText = prompt
                                Task { await viewModel.send() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(viewModel.isSending)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 8)

                HStack(alignment: .center, spacing: 8) {
                    ChatInputField(
                        text: $viewModel.inputText,
                        placeholder: "メッセージを入力",
                        isFocused: isInputFocused,
                        onSubmit: {
                            Task { await viewModel.send() }
                        }
                    )
                    .frame(height: 36)
                    .onTapGesture {
                        isInputFocused = true
                    }

                    Button {
                        isInputFocused = false
                        Task { await viewModel.send() }
                    } label: {
                        if viewModel.isSending {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                    }
                    .disabled(viewModel.isSending || viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            }
            .navigationTitle("チャット")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("サインアウト") {
                        accessToken = nil
                    }
                }
            }
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            Text(message.content.isEmpty && message.role == .assistant ? "..." : message.content)
                .padding(12)
                .background(message.role == .user ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14))

            if message.role != .user {
                Spacer(minLength: 40)
            }
        }
    }
}
