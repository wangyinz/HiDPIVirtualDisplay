import Foundation

@main struct VirtualRenderScaleTests {
    static func main() {
        var checks = 0
        func check(_ passed: Bool, _ message: String) { checks += 1; precondition(passed, message) }
        let original = PresetConfig(name: "8K-4800", width: 9600, height: 5400,
            logicalWidth: 4800, logicalHeight: 2700, ppi: 163, hiDPI: true)
        let standard = original.rendered(at: .standard)
        check(standard.logicalWidth == 4800 && standard.logicalHeight == 2700,
              "Changing density must not halve the workspace")
        check(standard.width == 4800 && standard.height == 2700 && !standard.hiDPI,
              "The manager needs 1x pixels AND hiDPI off")
        check(standard.name == original.name && standard.ppi == original.ppi, "Keep display identity")
        check(standard.rendered(at: .hiDPI) == original, "Return from 1x to the exact prior 2x preset")
        for scale in VirtualRenderScale.allCases {
            let config = original.rendered(at: scale)
            check(config.rendered(at: scale) == config, "Connection retries must not rescale an already scaled buffer")
            let menuNumber = scale.rawValue as NSNumber
            check(VirtualRenderScale.preference(menuNumber.intValue) == scale, "Menu and saved preference round trip")
        }
        for saved in [0, -1, 3, 160] {
            check(VirtualRenderScale.preference(saved) == .hiDPI, "Missing or invalid preference preserves legacy HiDPI")
        }
        let custom = PresetConfig(name: "Custom-4801x2701", width: 4801, height: 2701,
            logicalWidth: 4801, logicalHeight: 2701, ppi: 163, hiDPI: false)
        let customHiDPI = custom.rendered(at: .hiDPI)
        check(customHiDPI.width == 9602 && customHiDPI.height == 5402,
              "A restored custom 1x preset also supports returning to 2x")
        check(customHiDPI.rendered(at: .standard) == custom, "Odd custom dimensions survive a round trip")
        check(standard.matchesSource(width: 4800, height: 2700, pixelWidth: 4800, pixelHeight: 2700), "Accept correct 1x readback")
        check(!standard.matchesSource(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080), "Reject OS-selected 1080p fallback before mirroring")
        check(!standard.matchesSource(width: 2400, height: 1350, pixelWidth: 4800, pixelHeight: 2700), "Reject accidental halved workspace")
        check(!standard.matchesSource(width: 4800, height: 2700, pixelWidth: 9600, pixelHeight: 5400), "Reject unchanged 2x framebuffer")
        check(!standard.matchesSource(width: 7680, height: 4320, pixelWidth: 7680, pixelHeight: 4320), "Physical mirror readback is not source verification")
        let source = RetainedDesktopSignature(displayID: 101, width: 4800, height: 2700,
            pixelWidth: 4800, pixelHeight: 2700, refreshRate: 90)
        let physical = DisplayTimingRequirement(width: 7680, height: 4320, refreshRate: 60)
        let link = DisplayLinkCapabilities(displayID: 2, width: 7680, height: 4320, fixedRefreshRates: [30, 60])
        var recovery = RetainedDisplayReconnect(desktop: source, requirement: physical)
        check(recovery.observe(desktop: source, capabilities: nil, physicalPresent: false, at: 600) == .disconnected,
              "A 1x source stays retained during an HDMI switch")
        check(recovery.observe(desktop: source, capabilities: link, physicalPresent: true, at: 601) == .waiting, "Keep connection gate at 1x")
        _ = recovery.observe(desktop: source, capabilities: link, physicalPresent: true, at: 602)
        check(recovery.observe(desktop: source, capabilities: link, physicalPresent: true, at: 603) == .ready, "Reattach the same 1x source")
        check(recovery.desktop == source && recovery.requirement == physical, "Density does not alter 90Hz source / 8K60 target requirements")
        print("Virtual render scale passed (\(checks) checks)")
    }
}
