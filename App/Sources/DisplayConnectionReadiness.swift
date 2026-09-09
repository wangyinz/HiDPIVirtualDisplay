import Foundation

/// A remembered successful native timing, independent of desktop scale.
struct DisplayTimingRequirement: Equatable {
    let width: Int
    let height: Int
    let refreshRate: Double

    init(width: Int, height: Int, refreshRate: Double) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
    }

    init?(dictionary: [String: Any]) {
        guard let w = dictionary["width"] as? NSNumber,
              let h = dictionary["height"] as? NSNumber,
              let r = dictionary["refreshRate"] as? NSNumber,
              w.doubleValue > 0, w.doubleValue <= 32768,
              h.doubleValue > 0, h.doubleValue <= 32768,
              w.doubleValue.rounded() == w.doubleValue,
              h.doubleValue.rounded() == h.doubleValue,
              r.doubleValue.isFinite, r.doubleValue > 0, r.doubleValue <= 1000 else { return nil }
        self.init(width: w.intValue, height: h.intValue, refreshRate: r.doubleValue)
    }

    static func recovering(remembered: Self?, capabilities: DisplayLinkCapabilities?,
                           preferredRate: Double) -> Self? {
        guard preferredRate.isFinite, preferredRate >= 0, preferredRate <= 1000 else { return nil }
        func area(_ width: Int?, _ height: Int?) -> Int {
            guard let width = width, let height = height,
                  (1...32768).contains(width), (1...32768).contains(height) else { return 0 }
            return width * height
        }
        let observedArea = area(capabilities?.width, capabilities?.height)
        let rememberedArea = area(remembered?.width, remembered?.height)
        let width = rememberedArea > observedArea ? remembered?.width : capabilities?.width
        let height = rememberedArea > observedArea ? remembered?.height : capabilities?.height
        let rate = preferredRate > 0 ? preferredRate :
            max(remembered?.refreshRate ?? 0, capabilities?.fixedRefreshRates.max() ?? 0)
        guard let width = width, let height = height, area(width, height) > 0,
              rate.isFinite, rate > 0, rate <= 1000 else { return nil }
        return Self(width: width, height: height, refreshRate: rate)
    }

    var dictionary: [String: Any] {
        ["width": width, "height": height, "refreshRate": refreshRate]
    }

    var title: String { "\(width)×\(height) @ \(Int(refreshRate.rounded())) Hz" }

    func accepts(_ capabilities: DisplayLinkCapabilities) -> Bool {
        capabilities.width == width && capabilities.height == height &&
        capabilities.fixedRefreshRates.contains { abs($0 - refreshRate) <= 0.5 }
    }

    func matchesPhysical(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int,
                         refreshRate: Double, variableRefresh: Bool,
                         requiresFixedRefresh: Bool = true) -> Bool {
        width == self.width && height == self.height &&
        pixelWidth == self.width && pixelHeight == self.height &&
        refreshRate.isFinite && abs(refreshRate - self.refreshRate) <= 0.5 &&
        (!requiresFixedRefresh || !variableRefresh)
    }
}

/// A single native-mode enumeration. VRR-only modes are excluded by the caller.
struct DisplayLinkCapabilities: Equatable {
    let displayID: UInt32
    let width: Int
    let height: Int
    let fixedRefreshRates: [Double]

    init(displayID: UInt32, width: Int, height: Int, fixedRefreshRates: [Double]) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.fixedRefreshRates = Array(Set(fixedRefreshRates.filter { $0.isFinite && $0 > 0 }
            .map { ($0 * 1000).rounded() / 1000 })).sorted()
    }
}

/// Require three matching observations over at least two seconds. A display ID
/// alone is insufficient: HDMI switches can enumerate the right TV before the
/// requested native timing is available. The absolute deadline never extends
/// when capabilities flap.
struct DisplayConnectionReadiness {
    enum Decision { case waiting, ready, timedOut }
    private var startedAt: TimeInterval?
    private var stableSince: TimeInterval?
    private var candidate: DisplayLinkCapabilities?
    private var candidateRequirement: DisplayTimingRequirement?
    private var samples = 0
    let timeout: TimeInterval
    let stableDuration: TimeInterval

    init(timeout: TimeInterval = 30, stableDuration: TimeInterval = 2) {
        self.timeout = timeout
        self.stableDuration = stableDuration
    }

    mutating func observe(_ capabilities: DisplayLinkCapabilities?,
                          requiring requirement: DisplayTimingRequirement?,
                          at now: TimeInterval) -> Decision {
        if startedAt == nil { startedAt = now }
        if now - (startedAt ?? now) > timeout { return .timedOut }
        if let capabilities = capabilities, let requirement = requirement,
           requirement.accepts(capabilities) {
            if candidate != capabilities || candidateRequirement != requirement {
                candidate = capabilities
                candidateRequirement = requirement
                stableSince = now
                samples = 1
            } else {
                samples += 1
            }
            if samples >= 3, let since = stableSince, now - since >= stableDuration {
                return .ready
            }
        } else {
            candidate = nil
            candidateRequirement = nil
            stableSince = nil
            samples = 0
        }
        if now - (startedAt ?? now) >= timeout { return .timedOut }
        return .waiting
    }
}
