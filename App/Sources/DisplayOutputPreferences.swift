import Foundation

/// Physical link fields, deliberately separate from CGDisplayMode's framebuffer.
struct DisplayOutputMode: Equatable, Codable {
    let bitsPerComponent: UInt32
    let range: UInt32
    let eotf: UInt32
    let encoding: UInt32

    init(bitsPerComponent: UInt32, range: UInt32, eotf: UInt32, encoding: UInt32) {
        self.bitsPerComponent = bitsPerComponent
        self.range = range
        self.eotf = eotf
        self.encoding = encoding
    }

    init?(dictionary: [String: Any]) {
        func word(_ key: String) -> UInt32? {
            guard let n = dictionary[key] as? NSNumber,
                  n.doubleValue >= 0, n.doubleValue <= Double(UInt32.max),
                  n.doubleValue.rounded(.towardZero) == n.doubleValue else { return nil }
            return n.uint32Value
        }
        guard let bits = word("bitsPerComponent"), let range = word("range"),
              let eotf = word("eotf"), let encoding = word("encoding") else { return nil }
        self.init(bitsPerComponent: bits, range: range, eotf: eotf, encoding: encoding)
    }

    var dictionary: [String: NSNumber] {
        ["bitsPerComponent": NSNumber(value: bitsPerComponent), "range": NSNumber(value: range),
         "eotf": NSNumber(value: eotf), "encoding": NSNumber(value: encoding)]
    }
    var isHDR: Bool { eotf == 2 && encoding < 4 }
    var isSelectable: Bool {
        [8, 10, 12, 16].contains(bitsPerComponent) && range <= 1 &&
        [0, 2].contains(eotf) && encoding <= 3
    }
    var title: String {
        let color = [0: "RGB", 1: "YCbCr 4:4:4", 2: "YCbCr 4:2:2", 3: "YCbCr 4:2:0"][Int(encoding)]
            ?? "Encoding \(encoding)"
        let rangeName = range == 1 ? "Full range" : (range == 0 ? "Limited range" : "Range \(range)")
        return "\(color) · \(bitsPerComponent) bit · \(rangeName)"
    }
    var statusTitle: String {
        let hdr = eotf == 0 ? "SDR" : (isHDR ? "HDR10" : "EOTF \(eotf)")
        return "\(hdr) · \(title)"
    }
}

/// Keep SDR and HDR choices separately: switching HDR off must not erase a
/// selected 12-bit HDR format just because that format is unavailable in SDR.
struct DisplayOutputPreference {
    var hdrEnabled: Bool
    var hdrMode: DisplayOutputMode?
    var sdrMode: DisplayOutputMode?

    init(hdrEnabled: Bool) {
        self.hdrEnabled = hdrEnabled
    }
    init?(dictionary: [String: Any]) {
        guard let hdr = dictionary["hdrEnabled"] as? Bool else { return nil }
        hdrEnabled = hdr
        hdrMode = (dictionary["hdrMode"] as? [String: Any]).flatMap(DisplayOutputMode.init(dictionary:))
        sdrMode = (dictionary["sdrMode"] as? [String: Any]).flatMap(DisplayOutputMode.init(dictionary:))
        if hdrMode?.isHDR != true || hdrMode?.isSelectable != true { hdrMode = nil }
        if sdrMode?.eotf != 0 || sdrMode?.isSelectable != true { sdrMode = nil }
    }
    var dictionary: [String: Any] {
        var result: [String: Any] = ["hdrEnabled": hdrEnabled]
        if let mode = hdrMode { result["hdrMode"] = mode.dictionary }
        if let mode = sdrMode { result["sdrMode"] = mode.dictionary }
        return result
    }
    func mode(forHDR hdr: Bool) -> DisplayOutputMode? { hdr ? hdrMode : sdrMode }
    mutating func select(_ mode: DisplayOutputMode?, forHDR hdr: Bool) {
        hdrEnabled = hdr
        if hdr { hdrMode = mode } else { sdrMode = mode }
    }
}

/// Only learn a manual System Settings change after two consistent samples.
/// The app does not feed observations here while a link is absent, asleep,
/// being rebuilt, or restoring preferences.
struct HDRSelectionObserver {
    private(set) var baseline: Bool?
    private var candidate: Bool?
    private var candidateSince: TimeInterval = 0

    mutating func reset(to hdr: Bool?) {
        baseline = hdr
        candidate = nil
    }

    mutating func observe(_ hdr: Bool, at now: TimeInterval) -> Bool? {
        guard let baseline = baseline else {
            reset(to: hdr)
            return nil
        }
        guard hdr != baseline else {
            candidate = nil
            return nil
        }
        if candidate != hdr {
            candidate = hdr
            candidateSince = now
            return nil
        }
        guard now - candidateSince >= 0.75 else { return nil }
        reset(to: hdr)
        return hdr
    }
}

/// A failed format must not cause an endless modeset/flicker loop.
struct OutputRestoreBudget {
    private(set) var pending = false
    private(set) var attempts = 0
    mutating func begin() { pending = true; attempts = 0 }
    mutating func consumeAttempt() -> Bool {
        guard pending, attempts < 3 else { return false }
        attempts += 1
        return true
    }
    mutating func finish() { pending = false }
}
