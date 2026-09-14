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
    enum Decision: Equatable { case disconnected, waiting, ready, unavailable, rebuild }
    let desktop: RetainedDesktopSignature
    let requirement: DisplayTimingRequirement
    private var readiness = DisplayConnectionReadiness()
    private var fastReadiness = DisplayConnectionReadiness(stableDuration: 0.5)
    private var linkUnavailable = false

    init(desktop: RetainedDesktopSignature, requirement: DisplayTimingRequirement) {
        self.desktop = desktop
        self.requirement = requirement
    }

    mutating func resetProbe() {
        readiness = DisplayConnectionReadiness()
        fastReadiness = DisplayConnectionReadiness(stableDuration: 0.5)
        linkUnavailable = false
    }

    mutating func observe(desktop current: RetainedDesktopSignature?,
                          capabilities: DisplayLinkCapabilities?, physicalPresent: Bool, at now: TimeInterval,
                          confirmedNativeSignal: Bool = false, fastReconnect: Bool = false) -> Decision {
        guard desktop.matches(current) else { return .rebuild }
        guard physicalPresent else {
            resetProbe()
            return .disconnected
        }
        if linkUnavailable {
            guard let capabilities = capabilities, requirement.accepts(capabilities) else { return .unavailable }
            resetProbe()
        }
        // A present mode list alone can precede a working HDMI link. Shorten
        // the gate only after the live target also reports native fixed scanout.
        let fastDecision = fastReadiness.observe(fastReconnect && confirmedNativeSignal ? capabilities : nil,
                                                 requiring: requirement, at: now)
        switch readiness.observe(capabilities, requiring: requirement, at: now) {
        case .waiting: return fastDecision == .ready ? .ready : .waiting
        case .ready: return .ready
        case .timedOut:
            linkUnavailable = true
            return .unavailable
        }
    }
}

/// CoreGraphics display transactions can pump the main run loop before returning.
/// A main-queue notification must not start a second transaction inside the first.
final class RetainedReconnectOperation {
    private(set) var isRunning = false

    @discardableResult
    func performIfIdle(_ operation: () -> Void) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        defer { isRunning = false }
        operation()
        return true
    }
}

/// A successful CoreGraphics transaction can briefly read back a placeholder
/// mode (observed as 1x1). Verify asynchronously without applying another mode.
struct RetainedMirrorVerification {
    enum Decision { case waiting, ready, failed }
    let targetDisplayID: UInt32
    let desktop: RetainedDesktopSignature
    let startedAt: TimeInterval
    private var stableSince: TimeInterval?
    private var samples = 0

    init(targetDisplayID: UInt32, desktop: RetainedDesktopSignature, startedAt: TimeInterval) {
        self.targetDisplayID = targetDisplayID
        self.desktop = desktop
        self.startedAt = startedAt
    }

    mutating func observe(desktop current: RetainedDesktopSignature?,
                          mirrorMatches: Bool, physicalMatches: Bool, at now: TimeInterval) -> Decision {
        if now - startedAt > 5 { return .failed }
        if desktop.matches(current) && mirrorMatches && physicalMatches {
            if stableSince == nil { stableSince = now }
            samples += 1
            if samples >= 3, let since = stableSince, now - since >= 1 { return .ready }
        } else {
            stableSince = nil
            samples = 0
        }
        return now - startedAt >= 5 ? .failed : .waiting
    }
}
