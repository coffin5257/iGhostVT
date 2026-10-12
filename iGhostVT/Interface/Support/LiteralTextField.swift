//
//  LiteralTextField.swift
//  iGhostVT
//

#if !targetEnvironment(macCatalyst)
    import SwiftUI
    import UIKit

    /// A one-line field that keeps every character as typed, in a monospaced
    /// face: no autocorrection, spell check, capitalisation or predictive
    /// text, and none of the smart punctuation SwiftUI's `TextField` has no
    /// switch for — two hyphens became an em dash there, and
    /// `--dangerously-skip-permissions` reached the shell as an argument it
    /// did not know. For text that ends up typed into a terminal.
    struct LiteralTextField: UIViewRepresentable {
        let placeholder: String
        @Binding var text: String
        var accessibilityLabel: String?

        func makeUIView(context: Context) -> UITextField {
            let field = UITextField(frame: .zero)
            field.font = UIFontMetrics(forTextStyle: .body).scaledFont(
                for: .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular),
            )
            field.adjustsFontForContentSizeCategory = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.smartDashesType = .no
            field.smartQuotesType = .no
            field.smartInsertDeleteType = .no
            if #available(iOS 17.0, *) {
                field.inlinePredictionType = .no
            }
            field.keyboardType = .asciiCapable
            field.returnKeyType = .done
            field.clearButtonMode = .whileEditing
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.delegate = context.coordinator
            field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
            return field
        }

        func updateUIView(_ field: UITextField, context: Context) {
            context.coordinator.text = $text
            if field.text != text {
                field.text = text
            }
            field.placeholder = placeholder
            field.accessibilityLabel = accessibilityLabel
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(text: $text)
        }

        final class Coordinator: NSObject, UITextFieldDelegate {
            var text: Binding<String>

            init(text: Binding<String>) {
                self.text = text
            }

            @objc func changed(_ field: UITextField) {
                text.wrappedValue = field.text ?? ""
            }

            func textFieldShouldReturn(_ field: UITextField) -> Bool {
                field.resignFirstResponder()
                return true
            }
        }
    }
#endif
