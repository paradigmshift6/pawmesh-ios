import SwiftUI

struct AddMoreTrackersView: View {
    let manager: OnboardingManager

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "pawprint.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("\(manager.configuredTrackerCount) Tracker\(manager.configuredTrackerCount == 1 ? "" : "s") Configured")
                    .font(.title2.bold())
                Text("Do you have another tracker to set up?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    manager.addAnotherTracker()
                } label: {
                    Label("Add Another Tracker", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Done") {
                    manager.finishOnboarding()
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}
