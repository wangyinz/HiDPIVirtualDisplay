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
        check(recovery.observe(desktop: desktop, capabilities: nil, physicalPresent: true, at: 30) == .rebuild, "Present target with absent EDID has bounded fallback")
        recovery = gate()
        for t in [0.0, 1, 10, 29] {
            check(recovery.observe(desktop: desktop, capabilities: degraded, physicalPresent: true, at: t) == .waiting, "Do not accept30Hz")
        }
        check(recovery.observe(desktop: desktop, capabilities: degraded, physicalPresent: true, at: 30) == .rebuild, "Bounded cold-rebuild fallback")

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
        print("Retained reconnect passed (\(checks) checks)")
    }
}
