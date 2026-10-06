import SwiftUI

struct ChatView: View {
    @Binding var accessToken: String?
    @State private var viewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool
    private let pushCenter = PushEventCenter.shared

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

                if let regError = pushCenter.registrationError {
                    Text("端末登録: \(regError)")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        #if targetEnvironment(simulator)
                        Button("テスト通知") {
                            SimulatorNotification.presentAgentBanner(
                                eventId: "1feb8516-72c2-43d9-b1eb-96580ce22d8a",
                                title: "エージェント",
                                body: "クラウドからの確認イベント"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("未配送イベントを取得") {
                            Task { await viewModel.pullPendingEvent() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(viewModel.isSending)
                        #endif

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
                        },
                        onFocusChange: { focused in
                            isInputFocused = focused
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
                        KeychainStore.deleteAll()
                        accessToken = nil
                    }
                }
            }
            .task {
                await handlePendingPushEvent()
            }
            .onChange(of: pushCenter.pendingEventId) { _, newValue in
                guard newValue != nil else { return }
                Task { await handlePendingPushEvent() }
            }
        }
    }

    private func handlePendingPushEvent() async {
        guard let eventId = pushCenter.consumePendingEventId() else { return }
        await viewModel.startFromEvent(eventId: eventId)
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
