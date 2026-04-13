import SwiftUI

/// Shows a progress checklist while the device is being configured.
struct ConfiguringDeviceView: View {
    let title: String
    let items: [ConfigItem]
    let error: String?

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            ProgressView()
                .scaleEffect(1.5)

            Text(title)
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.done ? .green : .secondary)
                            .font(.title3)
                        Text(item.label)
                            .foregroundStyle(item.done ? .primary : .secondary)
                    }
                }
            }
            .padding(.horizontal, 40)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Text("Do not disconnect the device")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }
}

/// Generic progress view for checking steps.
struct ProgressStepView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView()
                .scaleEffect(1.5)
            Text(title)
                .font(.title2.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

/// Success view with a button to continue.
struct DeviceReadyStepView: View {
    let title: String
    let message: String
    let systemImage: String
    let buttonLabel: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: systemImage)
                .font(.system(size: 64))
                .foregroundStyle(.green)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.bold())
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                action()
            } label: {
                Text(buttonLabel)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}
