import Foundation

@main
struct SavedPresetReconnectTests {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }
    static func main() {
        // Replay the September 14 trip. The office monitor reused display ID 2;
        // the caller resolves the saved fingerprint, not the numeric display ID.
        var state = SavedPresetReconnect(pending: true)
        check(state.observe(targetPresent: false, enabled: true, hasSavedPreset: true) == .waiting,
              "Internal display only after cleanup must keep Samsung pending")
        for _ in 0..<8 {
            check(state.observe(targetPresent: false, enabled: true, hasSavedPreset: true) == .waiting,
                  "Office notifications and backup polls must not consume Samsung reconnect")
            check(state.pending, "The pending flag must survive an unrelated monitor")
        }
        state = SavedPresetReconnect(pending: state.pending) // process restart at the office
        check(state.observe(targetPresent: false, enabled: true, hasSavedPreset: true) == .waiting,
              "Persisted intent survives restart with another monitor attached")
        check(state.observe(targetPresent: true, enabled: true, hasSavedPreset: true) == .ready,
              "Returning home automatically requests the saved preset")
        check(state.pending, "Scheduling a delayed restore does not consume intent")
        // Disconnect while the delayed operation is queued, then return again.
        check(state.observe(targetPresent: false, enabled: true, hasSavedPreset: true) == .waiting,
              "A canceled restore remains pending")
        check(state.observe(targetPresent: true, enabled: true, hasSavedPreset: true) == .ready,
              "Retry when the actual saved monitor returns")
        state.pending = false // restore has actually started
        check(state.observe(targetPresent: true, enabled: true, hasSavedPreset: true) == .idle,
              "The same connection must not repeatedly rebuild")

        var missedDisconnect = SavedPresetReconnect()
        check(missedDisconnect.observe(targetPresent: false, enabled: true, hasSavedPreset: true) == .waiting,
              "Startup or wake away from Samsung repairs a missing disconnected flag")
        check(missedDisconnect.observe(targetPresent: true, enabled: true, hasSavedPreset: true) == .ready,
              "A later Samsung connection restores after a missed unplug")

        var disabled = SavedPresetReconnect(pending: true)
        check(disabled.observe(targetPresent: true, enabled: false, hasSavedPreset: true) == .idle,
              "Turning off Auto-Apply suppresses automatic creation")
        check(disabled.observe(targetPresent: true, enabled: true, hasSavedPreset: true) == .ready,
              "Re-enabling Auto-Apply can use the saved intent")
        check(disabled.observe(targetPresent: false, enabled: true, hasSavedPreset: false) == .idle,
              "Disable HiDPI clears the saved preset and must remain disabled")
        check(!disabled.pending, "No stale pending flag after intentional disable")
        check(disabled.observe(targetPresent: true, enabled: true, hasSavedPreset: false) == .idle,
              "Plugging Samsung back in must not undo intentional disable")
        check(SavedPresetReconnect().pending == false, "First run has no pending reconnect")
        checkAllPresetFamilies()
        print("Saved preset reconnect: \(assertions) checks passed (all \(presetConfigs.count) built-in presets and custom QHD/5K)")
    }
    static func checkAllPresetFamilies() {
        // Synthetic EDID identities deliberately vary independently of the
        // preset family, so a brand whitelist cannot satisfy these cases.
        let families: [(String, Int, Int, Double)] = [
            ("8k-", 7680, 4320, 60), ("g9-57-", 7680, 2160, 120),
            ("g9-49-", 5120, 1440, 240), ("uw34-", 3440, 1440, 144),
            ("uw38-", 3840, 1600, 75), ("4k-", 3840, 2160, 60)
        ]
        var coveredFamilies = Set<String>()
        for (index, key) in presetConfigs.keys.sorted().enumerated() {
            guard let family = families.first(where: { key.hasPrefix($0.0) }) else {
                fatalError("Add test timing for new preset family: \(key)")
            }
            coveredFamilies.insert(family.0)
            let config = resolveSavedPreset(key, custom: nil)
            check(config == presetConfigs[key], "Use the actual catalog when restoring \(key)")
            verifyReturn(config: config!, nativeWidth: family.1, nativeHeight: family.2,
                         refreshRate: family.3, identityIndex: index)
        }
        check(coveredFamilies.count == families.count, "Exercise every shipped preset family")
        for (index, dimensions) in [(1728, 972, 2560, 1440), (3200, 1800, 5120, 2880)].enumerated() {
            let (width, height, nativeWidth, nativeHeight) = dimensions
            let custom: [String: Any] = ["name": "Custom desktop", "width": width,
                "height": height, "logicalWidth": width, "logicalHeight": height,
                "ppi": 110, "hiDPI": false]
            let config = resolveSavedPreset("custom-\(width)x\(height)", custom: custom)
            check(config?.logicalWidth == UInt32(width) && config?.logicalHeight == UInt32(height),
                  "Restore custom dimensions without a standard preset or an 8K assumption")
            verifyReturn(config: config!, nativeWidth: nativeWidth, nativeHeight: nativeHeight,
                         refreshRate: 60, identityIndex: 100 + index)
        }
        check(resolveSavedPreset("missing-preset", custom: nil) == nil, "Unknown standard preset is rejected")
        check(resolveSavedPreset("custom-1234x567", custom: ["name": "Incomplete"]) == nil,
              "Incomplete custom state cannot create a display")

        let saved = SavedMonitorFingerprint(vendor: 42, model: 10, serial: 99)
        check(saved.matches(.init(vendor: 42, model: 11, serial: 99)),
              "Nonzero serial can identify a panel whose mode-dependent model ID changed")
        check(!saved.matches(.init(vendor: 43, model: 10, serial: 99)),
              "A matching model or serial from a different vendor is not the saved panel")
        check(!saved.matches(.init(vendor: 42, model: 11, serial: 100)),
              "Different model and serial do not match")
        let noSerial = SavedMonitorFingerprint(vendor: 42, model: 10, serial: 0)
        check(noSerial.matches(.init(vendor: 42, model: 10, serial: 0)), "Panels without serials can restore")
        check(!noSerial.matches(.init(vendor: 42, model: 11, serial: 0)), "Zero serials cannot match different models")
    }

    static func verifyReturn(config: PresetConfig, nativeWidth: Int, nativeHeight: Int,
                             refreshRate: Double, identityIndex: Int) {
        let saved = SavedMonitorFingerprint(vendor: 100 + identityIndex,
            model: 200 + identityIndex, serial: identityIndex % 2 == 0 ? 0 : 300 + identityIndex)
        let other = SavedMonitorFingerprint(vendor: saved.vendor + 1000, model: saved.model, serial: saved.serial)
        var state = SavedPresetReconnect()
        check(state.observe(targetPresent: saved.matches(other), enabled: true, hasSavedPreset: true) == .waiting,
              "An unrelated panel keeps \(config.name) pending")
        // Multiple external monitors, with the saved one enumerated second.
        let found = [other, saved].contains(where: saved.matches)
        check(state.observe(targetPresent: found, enabled: true, hasSavedPreset: true) == .ready,
              "Restore \(config.name) for any vendor, even when its panel is not first")
        let capabilities = DisplayLinkCapabilities(displayID: 7, width: nativeWidth,
            height: nativeHeight, fixedRefreshRates: [refreshRate])
        let timing = DisplayTimingRequirement.recovering(remembered: nil, capabilities: capabilities, preferredRate: 0)
        check(timing == DisplayTimingRequirement(width: nativeWidth, height: nativeHeight, refreshRate: refreshRate),
              "Use the panel's native timing, not a hard-coded 8K60 requirement")
        var readiness = DisplayConnectionReadiness()
        _ = readiness.observe(capabilities, requiring: timing, at: 0)
        _ = readiness.observe(capabilities, requiring: timing, at: 1)
        check(readiness.observe(capabilities, requiring: timing, at: 2) == .ready,
              "The actual connection gate accepts this panel's resolution and refresh rate")
        for density in VirtualRenderScale.allCases {
            let rendered = config.rendered(at: density)
            check(rendered.logicalWidth == config.logicalWidth && rendered.logicalHeight == config.logicalHeight,
                  "Restore the selected logical size for \(config.name)")
            check(rendered.width == config.logicalWidth * UInt32(density.rawValue) &&
                  rendered.height == config.logicalHeight * UInt32(density.rawValue),
                  "Both 1x and 2x use this preset's dimensions")
        }
    }

}
