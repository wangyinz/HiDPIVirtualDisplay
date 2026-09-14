import Foundation

/// The saved monitor remains pending while a laptop or an unrelated display
/// is used. Presence of any external display is not a successful reconnect.
struct SavedPresetReconnect {
    enum Decision { case idle, waiting, ready }
    var pending = false

    mutating func observe(targetPresent: Bool, enabled: Bool, hasSavedPreset: Bool) -> Decision {
        guard hasSavedPreset else {
            pending = false
            return .idle
        }
        guard enabled else { return .idle }
        guard targetPresent else {
            pending = true
            return .waiting
        }
        // Leave pending set until the delayed restore actually starts. A
        // notification, canceled delay, or unrelated monitor cannot consume it.
        return pending ? .ready : .idle
    }
}

/// EDID identity matching is independent of brand, pixel dimensions and preset.
/// Retain the existing model-or-nonzero-serial compatibility rule: some panels
/// change product IDs when their link mode changes, and others omit serials.
struct SavedMonitorFingerprint {
    let vendor: Int
    let model: Int
    let serial: Int

    func matches(_ connected: Self) -> Bool {
        vendor == connected.vendor && (model == connected.model ||
            (serial != 0 && connected.serial != 0 && serial == connected.serial))
    }
}
