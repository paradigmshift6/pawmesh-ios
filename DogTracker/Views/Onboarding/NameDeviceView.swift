import SwiftUI

/// Lets the user name a device during onboarding setup.
struct NameDeviceView: View {
    let manager: OnboardingManager
    let title: String
    let subtitle: String
    let systemImage: String
    let placeholder: String
    let isRequired: Bool

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: systemImage)
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            TextField(placeholder, text: Binding(
                get: { manager.deviceName },
                set: { manager.deviceName = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.title3)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            .focused($focused)
            .submitLabel(.continue)
            .onSubmit {
                if canContinue {
                    manager.advance()
                }
            }

            Spacer()

            Button {
                manager.advance()
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canContinue)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .onAppear { focused = true }
    }

    private var canContinue: Bool {
        if isRequired {
            return !manager.deviceName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }
}
