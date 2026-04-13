import SwiftUI

/// Lets the user pick their LoRa region before configuring devices.
struct RegionSelectView: View {
    let manager: OnboardingManager

    private let regions: [(Config.LoRaConfig.RegionCode, String)] = [
        (.us, "United States"),
        (.eu868, "Europe (868 MHz)"),
        (.eu433, "Europe (433 MHz)"),
        (.cn, "China"),
        (.jp, "Japan"),
        (.anz, "Australia / New Zealand"),
        (.kr, "South Korea"),
        (.tw, "Taiwan"),
        (.ru, "Russia"),
        (.in, "India"),
        (.nz865, "New Zealand (865 MHz)"),
        (.th, "Thailand"),
        (.ua868, "Ukraine (868 MHz)"),
        (.ua433, "Ukraine (433 MHz)"),
        (.lora24, "2.4 GHz (worldwide)"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Select the LoRa frequency region for your area. All your devices must use the same region.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Region") {
                    ForEach(regions, id: \.0) { region, name in
                        Button {
                            manager.selectedRegion = region
                        } label: {
                            HStack {
                                Text(name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if manager.selectedRegion == region {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("LoRa Region")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        manager.advance()
                    }
                }
            }
        }
    }
}
