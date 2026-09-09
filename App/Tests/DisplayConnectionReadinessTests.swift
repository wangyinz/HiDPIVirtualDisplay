import Foundation

@main
struct DisplayConnectionReadinessTests {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }
    static func main() {
        let expected = DisplayTimingRequirement(width: 7680, height: 4320, refreshRate: 60)
        let full = DisplayLinkCapabilities(displayID: 2, width: 7680, height: 4320,
                                           fixedRefreshRates: [24, 30, 59.94, 60])
        let limited = DisplayLinkCapabilities(displayID: 2, width: 7680, height: 4320,
                                              fixedRefreshRates: [24, 25, 30])
        var gate = DisplayConnectionReadiness()
        check(gate.observe(limited, requiring: expected, at: 0) == .waiting, "Do not create 30 Hz source")
        check(gate.observe(limited, requiring: expected, at: 29) == .waiting, "Wait without resetting deadline")
        check(gate.observe(limited, requiring: expected, at: 30) == .timedOut, "Bounded wait")
        gate = DisplayConnectionReadiness()
        check(gate.observe(full, requiring: expected, at: 0) == .waiting, "First ready observation is insufficient")
        check(gate.observe(full, requiring: expected, at: 1) == .waiting, "Second observation is insufficient")
        check(gate.observe(full, requiring: expected, at: 2) == .ready, "Stable 60 Hz can proceed")
        gate = DisplayConnectionReadiness()
        _ = gate.observe(full, requiring: expected, at: 0)
        _ = gate.observe(limited, requiring: expected, at: 1)
        check(gate.observe(full, requiring: expected, at: 2) == .waiting, "A flap resets stability")
        check(gate.observe(full, requiring: expected, at: 3) == .waiting, "Do not reuse pre-flap time")
        check(gate.observe(full, requiring: expected, at: 4) == .ready, "Recover after stability")
        gate = DisplayConnectionReadiness()
        _ = gate.observe(full, requiring: expected, at: 0)
        _ = gate.observe(full, requiring: expected, at: 1)
        let newID = DisplayLinkCapabilities(displayID: 7, width: 7680, height: 4320,
                                            fixedRefreshRates: full.fixedRefreshRates)
        check(gate.observe(newID, requiring: expected, at: 2) == .waiting, "A new display ID resets stability")
        _ = gate.observe(newID, requiring: expected, at: 3)
        check(gate.observe(newID, requiring: expected, at: 4) == .ready, "New ID can settle")
        gate = DisplayConnectionReadiness()
        _ = gate.observe(full, requiring: expected, at: 0)
        _ = gate.observe(full, requiring: expected, at: 1)
        check(gate.observe(full, requiring: expected, at: 31) == .timedOut, "A delayed callback cannot exceed the absolute deadline")
        let fourK = DisplayLinkCapabilities(displayID: 2, width: 3840, height: 2160, fixedRefreshRates: [60])
        check(!expected.accepts(fourK), "4K 60 cannot satisfy remembered 8K 60")
        check(DisplayTimingRequirement.recovering(remembered: expected, capabilities: limited, preferredRate: 0) == expected,
              "Auto must not silently downgrade a previously successful timing")
        check(DisplayTimingRequirement.recovering(remembered: expected, capabilities: fourK, preferredRate: 0) == expected,
              "Temporary low-resolution capabilities must not erase native dimensions")
        let explicit120 = DisplayTimingRequirement.recovering(remembered: expected, capabilities: full, preferredRate: 120)
        check(explicit120?.refreshRate == 120, "Explicit 120 must not be represented as a 60 Hz request")
        check(!explicit120!.accepts(full), "Unavailable explicit request must wait")
        check(DisplayTimingRequirement.recovering(remembered: nil, capabilities: full, preferredRate: 0) == expected,
              "First launch Auto chooses available native rate")
        check(DisplayTimingRequirement.recovering(remembered: expected, capabilities: nil, preferredRate: 0) == expected,
              "Remember the target during a complete disconnect")
        check(DisplayTimingRequirement.recovering(remembered: nil, capabilities: nil, preferredRate: 60) == nil,
              "No dimensions means no invented display")
        check(DisplayTimingRequirement.recovering(remembered: expected, capabilities: full, preferredRate: .nan) == nil,
              "Reject malformed preference")
        check(expected.matchesPhysical(width: 7680, height: 4320, pixelWidth: 7680, pixelHeight: 4320,
                                       refreshRate: 59.94, variableRefresh: false), "Accept fixed 59.94")
        check(!expected.matchesPhysical(width: 3840, height: 2160, pixelWidth: 7680, pixelHeight: 4320,
                                        refreshRate: 60, variableRefresh: false), "Reject 2x physical cursor-regression mode")
        check(!expected.matchesPhysical(width: 7680, height: 4320, pixelWidth: 7680, pixelHeight: 4320,
                                        refreshRate: 30, variableRefresh: false), "Fixed 30 is not a healthy saved-60 mirror")
        check(!expected.matchesPhysical(width: 7680, height: 4320, pixelWidth: 7680, pixelHeight: 4320,
                                        refreshRate: 60, variableRefresh: true), "VRR maximum 60 is not fixed 60")
        check(expected.matchesPhysical(width: 7680, height: 4320, pixelWidth: 7680, pixelHeight: 4320,
                                       refreshRate: 60, variableRefresh: true, requiresFixedRefresh: false),
              "A manual HDR toggle that enables VRR can still be observed before fixed-rate repair")
        check(!expected.matchesPhysical(width: 7680, height: 4320, pixelWidth: 7680, pixelHeight: 4320,
                                        refreshRate: 30, variableRefresh: true, requiresFixedRefresh: false),
              "HDR observation must still reject temporary 30 Hz")
        check(!expected.matchesPhysical(width: 3840, height: 2160, pixelWidth: 7680, pixelHeight: 4320,
                                        refreshRate: 60, variableRefresh: true, requiresFixedRefresh: false),
              "HDR observation must still reject an incorrect physical coordinate scale")
        check(DisplayTimingRequirement(dictionary: expected.dictionary) == expected, "Stable timing preference round trip")
        check(DisplayTimingRequirement(dictionary: ["width": 7680, "height": 4320, "refreshRate": Double.infinity]) == nil,
              "Reject invalid persisted timing")
        print("Display connection readiness tests passed (\(assertions) assertions)")
    }
}
