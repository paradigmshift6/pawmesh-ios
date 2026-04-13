import SwiftUI

struct WelcomeStepView: View {
    let manager: OnboardingManager

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "pawprint.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.tint)

            VStack(spacing: 12) {
                Text("Dog Tracker")
                    .font(.largeTitle.bold())
                Text("Track your dogs in the backcountry\nusing Meshtastic radios.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(icon: "antenna.radiowaves.left.and.right", title: "No cell service needed", subtitle: "Uses LoRa mesh radio for miles of range")
                FeatureRow(icon: "map.fill", title: "Offline topo maps", subtitle: "Download USGS maps before you go")
                FeatureRow(icon: "location.fill", title: "Real-time GPS", subtitle: "See your dogs on the map with live updates")
            }
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    manager.advance()
                } label: {
                    Text("Get Started")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("I've already set up my devices") {
                    manager.skip()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
