import Foundation

@main
struct DisplayOutputPreferencesTests {
    static func main() throws {
        let hdr12 = DisplayOutputMode(bitsPerComponent: 12, range: 1, eotf: 2, encoding: 0)
        let sdr10 = DisplayOutputMode(bitsPerComponent: 10, range: 1, eotf: 0, encoding: 0)
        var preference = DisplayOutputPreference(hdrEnabled: true)
        preference.select(hdr12, forHDR: true)
        preference.select(sdr10, forHDR: false)
        let saved = try PropertyListSerialization.data(fromPropertyList: preference.dictionary, format: .binary, options: 0)
        let plist = try PropertyListSerialization.propertyList(from: saved, format: nil) as! [String: Any]
        var restored = DisplayOutputPreference(dictionary: plist)!
        precondition(!restored.hdrEnabled)
        precondition(restored.mode(forHDR: false) == sdr10)
        precondition(restored.mode(forHDR: true) == hdr12)
        restored.hdrEnabled = true
        precondition(restored.mode(forHDR: true) == hdr12, "HDR off/on must retain the HDR format")
        restored.select(nil, forHDR: true)
        precondition(restored.mode(forHDR: true) == nil)
        precondition(restored.mode(forHDR: false) == sdr10, "Automatic HDR must not erase the SDR choice")

        var observer = HDRSelectionObserver()
        observer.reset(to: true)
        precondition(observer.observe(false, at: 1) == nil)
        precondition(observer.observe(true, at: 1.5) == nil, "Transient SDR must not become the preference")
        precondition(observer.observe(false, at: 2) == nil)
        precondition(observer.observe(false, at: 2.5) == nil)
        precondition(observer.observe(false, at: 2.8) == false, "Stable manual HDR off must be learned")
        precondition(observer.observe(false, at: 4) == nil, "Do not repeatedly save an unchanged choice")
        // Restore learns its final readback as a baseline, not as a user choice.
        observer.reset(to: false)
        precondition(observer.observe(false, at: 7) == nil)
        precondition(observer.observe(true, at: 8) == nil)
        precondition(observer.observe(true, at: 9) == true)

        var budget = OutputRestoreBudget()
        precondition(!budget.consumeAttempt())
        budget.begin()
        for _ in 0..<3 { precondition(budget.consumeAttempt()) }
        for _ in 0..<10 { precondition(!budget.consumeAttempt(), "Failures must not modeset forever") }
        budget.finish()
        precondition(!budget.pending)
        budget.begin()
        precondition(budget.consumeAttempt(), "A new reconnect or explicit choice permits a fresh retry")

        precondition(DisplayOutputMode(dictionary: ["bitsPerComponent": -1, "range": 1, "eotf": 2, "encoding": 0]) == nil)
        precondition(DisplayOutputMode(dictionary: ["bitsPerComponent": 10.5, "range": 1, "eotf": 2, "encoding": 0]) == nil)
        let unknown = DisplayOutputMode(bitsPerComponent: 12, range: 1, eotf: 9, encoding: 99)
        precondition(!unknown.isSelectable, "Unknown private enums must not be selectable")
        let corrupt = DisplayOutputPreference(dictionary: ["hdrEnabled": true, "hdrMode": sdr10.dictionary])
        precondition(corrupt?.hdrMode == nil, "Never restore an SDR format as the HDR preference")
        print("PASS: HDR/SDR persistence, manual HDR debounce, restore readback baseline, bounded retries, format validation.")
    }
}
