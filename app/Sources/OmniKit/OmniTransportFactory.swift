import Foundation

/// Picks the transport the app should use.
public enum OmniTransportFactory {
    /// Set to `1` to run against `SimulatedOmniTransport` instead of real hardware.
    public static let simulationEnvironmentKey = "HUSHDECK_SIMULATED_OMNI"

    public static func isSimulationRequested(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let value = environment[simulationEnvironmentKey]?.lowercased() else { return false }
        return ["1", "true", "yes"].contains(value)
    }

    /// `SimulatedOmniTransport(configuration: .demo)` when `HUSHDECK_SIMULATED_OMNI=1`,
    /// otherwise `IOKitOmniTransport`.
    public static func makeDefault(environment: [String: String] = ProcessInfo.processInfo.environment) -> any OmniTransport {
        if isSimulationRequested(environment: environment) {
            return SimulatedOmniTransport(configuration: .demo)
        }
        return IOKitOmniTransport()
    }
}
