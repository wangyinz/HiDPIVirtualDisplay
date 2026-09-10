import Foundation

/// Render density is independent of desktop size, mirror output and cadence.
/// Missing/unknown preferences keep the existing 2x rendering behavior.
enum VirtualRenderScale: Int, CaseIterable {
    case standard = 1
    case hiDPI = 2

    static let preferenceKey = "virtualRenderScale"

    static func preference(_ value: Int) -> VirtualRenderScale {
        VirtualRenderScale(rawValue: value) ?? .hiDPI
    }

    var title: String {
        self == .hiDPI ? "HiDPI (2×)" : "Standard (1×, non-HiDPI)"
    }
}

struct PresetConfig: Equatable {
    let name: String
    let width: UInt32      // Framebuffer width
    let height: UInt32     // Framebuffer height
    let logicalWidth: UInt32
    let logicalHeight: UInt32
    let ppi: UInt32
    let hiDPI: Bool

    /// Derive pixels from logical dimensions every time. This is idempotent
    /// across retry/restore and also restores 2x from a saved 1x custom preset.
    func rendered(at scale: VirtualRenderScale) -> PresetConfig {
        let factor = UInt32(scale.rawValue)
        return PresetConfig(name: name, width: logicalWidth * factor,
            height: logicalHeight * factor, logicalWidth: logicalWidth,
            logicalHeight: logicalHeight, ppi: ppi, hiDPI: scale == .hiDPI)
    }

    func matchesSource(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int) -> Bool {
        width == Int(logicalWidth) && height == Int(logicalHeight) &&
            pixelWidth == Int(self.width) && pixelHeight == Int(self.height)
    }
}
