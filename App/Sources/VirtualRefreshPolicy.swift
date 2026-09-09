import Foundation

/// Keep the physical output requirement independent of virtual render cadence.
/// Multipliers are opt-in. If the result exceeds 240 Hz, keep the physical rate.
enum VirtualRefreshPolicy: Double, CaseIterable {
    case matched = 1
    case increased = 1.25
    case intermediate = 1.5
    case fineLow = 1.5625
    case fineMiddle = 1.625
    case fineHigh = 1.6875
    case higher = 1.75
    case nearDouble = 1.875
    case doubled = 2

    static func preference(_ value: Double) -> VirtualRefreshPolicy {
        VirtualRefreshPolicy(rawValue: value) ?? .matched
    }

    func sourceRate(for physicalRate: Double) -> Double {
        guard physicalRate.isFinite, physicalRate > 0 else { return 0 }
        guard self != .matched else { return physicalRate }
        // macOS reported 97 Hz for a requested 97.5 Hz virtual mode. Normalize
        // opt-in rates before creation so source health checks use the same Hz.
        let requested = (physicalRate * rawValue).rounded()
        return requested > 0 && requested <= 240 ? requested : physicalRate
    }
}
