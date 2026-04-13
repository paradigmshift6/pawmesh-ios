import SwiftUI

/// Root onboarding wizard. Switches between step views based on
/// OnboardingManager state.
struct OnboardingContainerView: View {
    var manager: OnboardingManager
    @Environment(RadioController.self) private var radio
    @Environment(MeshService.self) private var mesh

    var body: some View {
        VStack {
            switch manager.step {
            case .welcome:
                WelcomeStepView(manager: manager)

            case .connectCompanion:
                ConnectDeviceStepView(
                    manager: manager,
                    radio: radio,
                    title: "Connect Companion Radio",
                    subtitle: "Power on your Heltec V3 and select it below.\nThis is the radio your phone connects to.",
                    systemImage: "antenna.radiowaves.left.and.right"
                )

            case .checkingCompanion:
                ProgressStepView(
                    title: "Checking Configuration",
                    message: "Reading current settings..."
                )
                .onAppear {
                    manager.setCapturedChannels(mesh.channels)
                }

            case .regionSelect:
                RegionSelectView(manager: manager)

            case .configuringCompanion:
                ConfiguringDeviceView(
                    title: "Setting Up Companion",
                    items: manager.configProgress,
                    error: manager.error
                )

            case .companionReady:
                DeviceReadyStepView(
                    title: "Companion Ready",
                    message: "Your companion radio is configured.\nNext, let's set up your dog tracker.",
                    systemImage: "checkmark.circle.fill",
                    buttonLabel: "Set Up Tracker",
                    action: { manager.advance() }
                )

            case .connectTracker:
                ConnectDeviceStepView(
                    manager: manager,
                    radio: radio,
                    title: "Connect Dog Tracker",
                    subtitle: "Power on the tracker and select it below.\nYou'll need to connect each tracker individually.",
                    systemImage: "pawprint.fill"
                )

            case .configuringTracker:
                ConfiguringDeviceView(
                    title: "Setting Up Tracker",
                    items: manager.configProgress,
                    error: manager.error
                )

            case .trackerReady:
                DeviceReadyStepView(
                    title: "Tracker Ready",
                    message: "Tracker configured for GPS broadcasting\nevery 2 minutes with 10m smart updates.",
                    systemImage: "checkmark.circle.fill",
                    buttonLabel: "Continue",
                    action: { manager.advance() }
                )

            case .addMoreTrackers:
                AddMoreTrackersView(manager: manager)

            case .complete:
                DeviceReadyStepView(
                    title: "All Set!",
                    message: "Your devices are configured.\nStart tracking your dogs!",
                    systemImage: "pawprint.circle.fill",
                    buttonLabel: "Start Tracking",
                    action: { manager.finishOnboarding() }
                )
            }
        }
        .animation(.easeInOut(duration: 0.3), value: manager.step)
    }
}
