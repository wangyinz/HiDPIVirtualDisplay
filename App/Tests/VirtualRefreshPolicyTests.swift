import Foundation
@main struct VirtualRefreshPolicyTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
        for rate in [24.0, 30, 59.94, 60, 120, 144, 160, 165, 192, 240, 300] {
            for policy in VirtualRefreshPolicy.allCases {
                let requested = policy == .matched ? rate : (rate * policy.rawValue).rounded()
                let expected = requested <= 240 ? requested : rate
                check(policy.sourceRate(for: rate) == expected, "Respect source cap without changing physical rate")
            }
        }
        for value in [0.0, 1, -1, 1.3, 3, 4, .nan, .infinity] {
            check(VirtualRefreshPolicy.preference(value) == .matched, "Unknown preference keeps native cadence")
        }
        for policy in VirtualRefreshPolicy.allCases {
            check(VirtualRefreshPolicy.preference(policy.rawValue) == policy, "Preference survives round trip")
            // Menu items carry NSNumber; fractional multipliers must not be truncated.
            let menuValue = policy.rawValue as NSNumber
            check(VirtualRefreshPolicy(rawValue: menuValue.doubleValue) == policy, "Menu value survives round trip")
            for value in [0.0, -1, .nan, .infinity] {
                check(policy.sourceRate(for: value) == 0, "No invalid rate propagated")
            }
        }
        check(VirtualRefreshPolicy.increased.sourceRate(for: 60) == 75, "75Hz intermediate mode")
        check(VirtualRefreshPolicy.intermediate.sourceRate(for: 60) == 90, "90Hz intermediate mode")
        check(VirtualRefreshPolicy.fineLow.sourceRate(for: 60) == 94, "94Hz fine mode")
        check(VirtualRefreshPolicy.fineMiddle.sourceRate(for: 60) == 98, "98Hz fine mode")
        check(VirtualRefreshPolicy.fineHigh.sourceRate(for: 60) == 101, "101Hz fine mode")
        check(VirtualRefreshPolicy.higher.sourceRate(for: 60) == 105, "105Hz intermediate mode")
        check(VirtualRefreshPolicy.nearDouble.sourceRate(for: 60) == 113, "113Hz intermediate mode")
        check(VirtualRefreshPolicy.doubled.sourceRate(for: 59.94) == 120, "Normalize source rate to avoid a false reconnect loop")
        check(VirtualRefreshPolicy.matched.sourceRate(for: 59.94) == 59.94, "Keep the default path unchanged")
        check(VirtualRefreshPolicy.preference(2) == .doubled, "8.10 preference remains compatible")
        let physical = DisplayTimingRequirement(width: 7680, height: 4320, refreshRate: 60)
        let link = DisplayLinkCapabilities(displayID: 2, width: 7680, height: 4320, fixedRefreshRates: [30, 60])
        check(physical.accepts(link), "A 60Hz-only physical link is sufficient for a 120Hz virtual source")
        check(VirtualRefreshPolicy.doubled.sourceRate(for: physical.refreshRate) == 120, "Source can double independently")
        check(physical.refreshRate == 60, "Physical requirement remains 60Hz")
        let degraded = DisplayLinkCapabilities(displayID: 2, width: 7680, height: 4320, fixedRefreshRates: [30])
        check(!physical.accepts(degraded), "Doubled source does not relax reconnect guard")
        print("Virtual refresh policy passed (\(checks) checks)")
    }
}
