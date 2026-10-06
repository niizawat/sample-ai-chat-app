import SwiftUI
import UIKit

/// シミュレータで AutoFill / ハードウェアキーボード干渉を避けるための入力欄。
struct ChatInputField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isFocused: Bool
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .send
    var autocapitalizationType: UITextAutocapitalizationType = .sentences
    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onFocusChange: onFocusChange)
    }

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.placeholder = placeholder
        textField.borderStyle = .roundedRect
        textField.returnKeyType = returnKeyType
        textField.keyboardType = keyboardType
        textField.isSecureTextEntry = isSecure
        textField.autocorrectionType = .no
        textField.autocapitalizationType = autocapitalizationType
        textField.spellCheckingType = .no
        textField.smartDashesType = .no
        textField.smartQuotesType = .no
        textField.smartInsertDeleteType = .no
        textField.textContentType = nil
        textField.passwordRules = nil
        textField.clearButtonMode = .whileEditing
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        context.coordinator.swiftUIWantsFocus = isFocused
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onFocusChange = onFocusChange
        uiView.isSecureTextEntry = isSecure
        uiView.keyboardType = keyboardType
        uiView.returnKeyType = returnKeyType
        uiView.autocapitalizationType = autocapitalizationType
        if uiView.text != text {
            uiView.text = text
        }

        // SwiftUI 側のフォーカス要求の遷移だけを見る。
        // UIKit が先に first responder になったあとの再描画で resign しない。
        let previousSwiftUIFocus = context.coordinator.swiftUIWantsFocus
        context.coordinator.swiftUIWantsFocus = isFocused

        if isFocused && !previousSwiftUIFocus && !uiView.isFirstResponder {
            DispatchQueue.main.async {
                _ = uiView.becomeFirstResponder()
            }
        } else if !isFocused && previousSwiftUIFocus && uiView.isFirstResponder {
            DispatchQueue.main.async {
                _ = uiView.resignFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String
        var onSubmit: (() -> Void)?
        var onFocusChange: ((Bool) -> Void)?
        var swiftUIWantsFocus = false

        init(
            text: Binding<String>,
            onSubmit: (() -> Void)?,
            onFocusChange: ((Bool) -> Void)?
        ) {
            _text = text
            self.onSubmit = onSubmit
            self.onFocusChange = onFocusChange
        }

        @objc func editingChanged(_ sender: UITextField) {
            text = sender.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            onFocusChange?(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            onFocusChange?(false)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onSubmit?()
            return true
        }
    }
}
