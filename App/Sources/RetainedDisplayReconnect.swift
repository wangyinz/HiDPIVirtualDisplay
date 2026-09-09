import Foundation

/// The desktop that must survive a retained-display reconnect unchanged.
struct RetainedDesktopSignature: Equatable {
    let displayID: UInt32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    func matches(_ other: Self?) -> Bool {
        guard let other = other else { return false }
        return displayID == other.displayID && width == other.width && height == other.height &&
            pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight &&
            refreshRate.isFinite && other.refreshRate.isFinite &&
            abs(refreshRate - other.refreshRate) <= 0.5
    }
}

/// Retaining an owned virtual display is independent from accepting the link.
/// Time spent on the other computer does not consume the 30-second link probe.
struct RetainedDisplayReconnect {
    enum Decision: Equatable { case disconnected, waiting, ready, rebuild }
    let desktop: RetainedDesktopSignature
    let requirement: DisplayTimingRequirement
    private var readiness = DisplayConnectionReadiness()

    init(desktop: RetainedDesktopSignature, requirement: DisplayTimingRequirement) {
        self.desktop = desktop
        self.requirement = requirement
    }

    mutating func resetProbe() { readiness = DisplayConnectionReadiness() }

    mutating func observe(desktop current: RetainedDesktopSignature?,
                          capabilities: DisplayLinkCapabilities?, physicalPresent: Bool, at now: TimeInterval) -> Decision {
        guard desktop.matches(current) else { return .rebuild }
        guard physicalPresent else {
            resetProbe()
            return .disconnected
        }
        switch readiness.observe(capabilities, requiring: requirement, at: now) {
        case .waiting: return .waiting
        case .ready: return .ready
        case .timedOut: return .rebuild
        }
    }
}
