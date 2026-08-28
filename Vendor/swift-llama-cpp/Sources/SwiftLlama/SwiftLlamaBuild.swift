public enum SwiftLlamaBuild {
    /// Physical iOS uses b10630. The hybrid's b6102 slice exists only so this
    /// Intel development Mac can keep building and driving iOS Simulator.
    public static let deviceIdentifier = "b10630"
    public static let intelSimulatorIdentifier = "b6102"

    public static var activeIdentifier: String {
        #if targetEnvironment(simulator) && arch(x86_64)
        intelSimulatorIdentifier
        #else
        deviceIdentifier
        #endif
    }
}
