import Foundation

@main struct RetainedDisplayReconnectTests {
    static func main() {
        var checks = 0
        func check(_ passed: Bool, _ message: String) { checks += 1; precondition(passed, message) }
        let desktop = RetainedDesktopSignature(displayID: 88, width: 5120, height: 2880,
            pixelWidth: 10240, pixelHeight: 5760, refreshRate: 90)
        let requirement = DisplayTimingRequirement(width: 7680, height: 4320, refreshRate: 60)
        let good = DisplayLinkCapabilities(displayID: 2, width: 7680, height: 4320, fixedRefreshRates: [30, 60])
        let degraded = DisplayLinkCapabilities(displayID: 2, width: 7680, height: 4320, fixedRefreshRates: [30])
        func gate() -> RetainedDisplayReconnect { .init(desktop: desktop, requirement: requirement) }
        var recovery = gate()
        for t in [0.0, 60, 600, 3600] {
            check(recovery.observe(desktop: desktop, capabilities: nil, physicalPresent: false, at: t) == .disconnected,
                  "Time on another computer must not force source destruction or consume the link deadline")
        }
        check(recovery.observe(desktop: desktop, capabilities: degraded, physicalPresent: true, at: 3601) == .waiting,
              "Transient8K30 must wait with the same source alive")
        check(recovery.observe(desktop: desktop, capabilities: good, physicalPresent: true, at: 3602) == .waiting, "First good observation")
        check(recovery.observe(desktop: desktop, capabilities: good, physicalPresent: true, at: 3603) == .waiting, "Do not skip stability gate")
        check(recovery.observe(desktop: desktop, capabilities: good, physicalPresent: true, at: 3604) == .ready, "Reuse after2s and3 observations")
        check(recovery.desktop == desktop && recovery.requirement == requirement, "90Hz virtual/60Hz physical remain independent")

        recovery = gate()
        check(recovery.observe(desktop: desktop, capabilities: nil, physicalPresent: true, at: 0) == .waiting, "EDID absent on present target still polls")
        check(recovery.observe(desktop: desktop, capabilities: nil, physicalPresent: true, at: 30) == .unavailable, "Present target with absent EDID pauses without destroying its desktop")
        recovery = gate()
        for t in [0.0, 1, 10, 29] {
            check(recovery.observe(desktop: desktop, capabilities: degraded, physicalPresent: true, at: t) == .waiting, "Do not accept30Hz")
        }
        check(recovery.observe(desktop: desktop, capabilities: degraded, physicalPresent: true, at: 30) == .unavailable, "Missing native timing pauses without forcing another process")

        recovery = gate()
        _ = recovery.observe(desktop: desktop, capabilities: good, physicalPresent: true, at: 0)
        _ = recovery.observe(desktop: desktop, capabilities: good, physicalPresent: true, at: 1)
        let changedID = DisplayLinkCapabilities(displayID: 9, width: 7680, height: 4320, fixedRefreshRates: [30, 60])
        check(recovery.observe(desktop: desktop, capabilities: changedID, physicalPresent: true, at: 2) == .waiting, "Changed physical ID restarts stability")
        _ = recovery.observe(desktop: desktop, capabilities: changedID, physicalPresent: true, at: 3)
        check(recovery.observe(desktop: desktop, capabilities: changedID, physicalPresent: true, at: 4) == .ready, "New physical ID can reuse same virtualID")

        for changed in [
            RetainedDesktopSignature(displayID: 99, width: 5120, height: 2880, pixelWidth: 10240, pixelHeight: 5760, refreshRate: 90),
            RetainedDesktopSignature(displayID: 88, width: 3840, height: 2160, pixelWidth: 7680, pixelHeight: 4320, refreshRate: 90),
            RetainedDesktopSignature(displayID: 88, width: 5120, height: 2880, pixelWidth: 5120, pixelHeight: 2880, refreshRate: 90),
            RetainedDesktopSignature(displayID: 88, width: 5120, height: 2880, pixelWidth: 10240, pixelHeight: 5760, refreshRate: 60)
        ] {
            recovery = gate()
            check(recovery.observe(desktop: changed, capabilities: good, physicalPresent: true, at: 0) == .rebuild, "Changed source/cursor geometry requires fallback")
        }
        recovery = gate()
        check(recovery.observe(desktop: nil, capabilities: nil, physicalPresent: false, at: 0) == .rebuild, "OS removed virtual display")
        recovery = gate()
        _ = recovery.observe(desktop: desktop, capabilities: degraded, physicalPresent: true, at: 0)
        check(recovery.observe(desktop: desktop, capabilities: nil, physicalPresent: false, at: 29) == .disconnected, "Another switch away parks again")
        _ = recovery.observe(desktop: desktop, capabilities: good, physicalPresent: true, at: 600)
        _ = recovery.observe(desktop: desktop, capabilities: good, physicalPresent: true, at: 601)
        check(recovery.observe(desktop: desktop, capabilities: good, physicalPresent: true, at: 602) == .ready, "A real disconnect starts a new bounded link attempt")
        recovery.resetProbe()
        check(recovery.observe(desktop: desktop, capabilities: good, physicalPresent: true, at: 1000) == .waiting, "Wake resets previous deadline")
        // Real failure regression: the main run loop delivers a configuration
        // notification from inside CGCompleteDisplayConfiguration. It must not
        // detach or mirror the target a second time before the first pin returns.
        let operation = RetainedReconnectOperation()
        var transactions = 0
        var detachments = 0
        var outerFinished = false
        func notification() {
            operation.performIfIdle { detachments += 1; transactions += 1 }
        }
        check(operation.performIfIdle {
            transactions += 1
            notification()
            check(operation.isRunning && !outerFinished, "Outer transaction owns nested notifications")
            outerFinished = true
        }, "Outer mirror transaction starts")
        check(transactions == 1 && detachments == 0 && outerFinished, "No reentrant detach/mirror during CoreGraphics transaction")
        check(!operation.isRunning, "Operation gate releases after synchronous transaction")
        notification()
        check(transactions == 2 && detachments == 1, "Later independent notification can run")

        func verifier() -> RetainedMirrorVerification {
            .init(targetDisplayID: 2, desktop: desktop, startedAt: 0)
        }
        var verification = verifier()
        check(verification.observe(desktop: desktop, mirrorMatches: true, physicalMatches: true, at: 0) == .waiting, "Immediate good transaction readback does not skip verification")
        check(verification.observe(desktop: desktop, mirrorMatches: true, physicalMatches: true, at: 0.5) == .waiting, "Two good samples are insufficient")
        check(verification.observe(desktop: desktop, mirrorMatches: true, physicalMatches: true, at: 1) == .ready, "Immediate first readback still requires three samples over one second")
        verification = verifier()
        let placeholderIsNative = requirement.matchesPhysical(width: 1, height: 1,
            pixelWidth: 1, pixelHeight: 1, refreshRate: 60, variableRefresh: false)
        check(verification.observe(desktop: desktop, mirrorMatches: true, physicalMatches: placeholderIsNative, at: 0.5) == .waiting,
              "Temporary 1x1 readback does not cause immediate teardown")
        check(verification.observe(desktop: desktop, mirrorMatches: true, physicalMatches: true, at: 1) == .waiting, "First good post-transaction readback")
        check(verification.observe(desktop: desktop, mirrorMatches: true, physicalMatches: true, at: 1.5) == .waiting, "Second readback still waits")
        check(verification.observe(desktop: desktop, mirrorMatches: true, physicalMatches: true, at: 2) == .ready, "Three good readbacks over one second finish recovery")
        verification = verifier()
        _ = verification.observe(desktop: desktop, mirrorMatches: true, physicalMatches: true, at: 0)
        _ = verification.observe(desktop: desktop, mirrorMatches: true, physicalMatches: false, at: 0.5)
        check(verification.observe(desktop: desktop, mirrorMatches: true, physicalMatches: true, at: 1) == .waiting, "Unstable physical readback resets stability")
        check(verification.observe(desktop: nil, mirrorMatches: true, physicalMatches: true, at: 5) == .failed, "Missing source after deadline requires bounded recovery")
        verification = verifier()
        check(verification.observe(desktop: desktop, mirrorMatches: false, physicalMatches: true, at: 5) == .failed, "Missing mirror fails verification")
        verification = verifier()
        check(verification.observe(desktop: desktop, mirrorMatches: true, physicalMatches: false, at: 5) == .failed, "Persistent scaled physical coordinates fail verification")
        verification = verifier()
        check(verification.observe(desktop: desktop, mirrorMatches: true, physicalMatches: true, at: 6) == .failed, "Late good readback does not bypass deadline")

        recovery = gate()
        _ = recovery.observe(desktop: desktop, capabilities: degraded, physicalPresent: true, at: 0)
        _ = recovery.observe(desktop: desktop, capabilities: degraded, physicalPresent: true, at: 30)
        check(recovery.observe(desktop: desktop, capabilities: degraded, physicalPresent: true, at: 600) == .unavailable, "Same 30Hz link remains paused without repeated timeout cycles")
        let stillDegraded = DisplayLinkCapabilities(displayID: 2, width: 7680, height: 4320, fixedRefreshRates: [24, 25, 30])
        check(recovery.observe(desktop: desktop, capabilities: stillDegraded, physicalPresent: true, at: 601) == .unavailable, "Unrelated changes in insufficient rates do not restart polling")
        check(recovery.observe(desktop: desktop, capabilities: good, physicalPresent: true, at: 602) == .waiting, "60Hz becoming available starts a new stability check")
        _ = recovery.observe(desktop: desktop, capabilities: good, physicalPresent: true, at: 603)
        check(recovery.observe(desktop: desktop, capabilities: good, physicalPresent: true, at: 604) == .ready, "Recover same retained source when bandwidth returns")
        print("Retained reconnect passed (\(checks) checks)")
    }
}
