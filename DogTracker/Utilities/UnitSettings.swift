import Foundation
import Observation

/// App-wide unit preference. Defaults to imperial (feet / miles).
@MainActor
@Observable
final class UnitSettings {
    var useMetric: Bool {
        didSet { UserDefaults.standard.set(useMetric, forKey: "useMetric") }
    }

    init() {
        self.useMetric = UserDefaults.standard.bool(forKey: "useMetric") // false = imperial default
    }
}
