import Foundation
import Security

/// Manages the private "DogTrk" channel used for secure position updates
/// between the companion node and all dog trackers.
enum ChannelManager {

    static let channelName = "DogTrk"
    static let channelIndex: Int32 = 1  // secondary channel

    private static let pskKey = "dogTrackerChannelPSK"

    /// Create a new private channel with a random AES-256 PSK.
    static func makePrivateChannel() -> Channel {
        let psk = generatePSK()
        savePSK(psk)
        return channelWith(psk: psk)
    }

    /// Create a channel using a previously saved PSK.
    /// Returns nil if no PSK has been saved yet.
    static func existingPrivateChannel() -> Channel? {
        guard let psk = loadPSK() else { return nil }
        return channelWith(psk: psk)
    }

    /// Check if a list of channels already contains our private channel.
    static func hasPrivateChannel(in channels: [Int32: Channel]) -> Bool {
        channels.values.contains { ch in
            ch.role == .secondary &&
            ch.settings.name == channelName &&
            ch.settings.psk.count == 32
        }
    }

    /// Extract and save the PSK from an existing channel config (e.g., read
    /// from a device that was already configured).
    static func adoptPSK(from channels: [Int32: Channel]) {
        if let ch = channels.values.first(where: {
            $0.role == .secondary && $0.settings.name == channelName && $0.settings.psk.count == 32
        }) {
            savePSK(ch.settings.psk)
        }
    }

    // MARK: - Private

    private static func channelWith(psk: Data) -> Channel {
        var settings = ChannelSettings()
        settings.name = channelName
        settings.psk = psk

        var channel = Channel()
        channel.index = channelIndex
        channel.role = .secondary
        channel.settings = settings
        return channel
    }

    /// Generate 32 random bytes (AES-256 key).
    private static func generatePSK() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        return Data(bytes)
    }

    static func savePSK(_ psk: Data) {
        UserDefaults.standard.set(psk, forKey: pskKey)
    }

    static func loadPSK() -> Data? {
        UserDefaults.standard.data(forKey: pskKey)
    }
}
