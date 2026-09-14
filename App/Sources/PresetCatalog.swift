import Foundation

/// Standard and custom restores use the same resolver for every display.
func resolveSavedPreset(_ name: String, custom: [String: Any]?) -> PresetConfig? {
    if let standard = presetConfigs[name] { return standard }
    guard name.hasPrefix("custom-"), let dict = custom,
          let displayName = dict["name"] as? String,
          let width = (dict["width"] as? NSNumber)?.uint32Value,
          let height = (dict["height"] as? NSNumber)?.uint32Value,
          let logicalWidth = (dict["logicalWidth"] as? NSNumber)?.uint32Value,
          let logicalHeight = (dict["logicalHeight"] as? NSNumber)?.uint32Value,
          let ppi = (dict["ppi"] as? NSNumber)?.uint32Value,
          let hiDPI = dict["hiDPI"] as? Bool else { return nil }
    return PresetConfig(name: displayName, width: width, height: height,
        logicalWidth: logicalWidth, logicalHeight: logicalHeight, ppi: ppi, hiDPI: hiDPI)
}

let presetConfigs: [String: PresetConfig] = [
    // 8K UHD (7680x4320 native). All presets preserve 16:9 and use a
    // framebuffer twice the logical dimensions in each direction.
    // 175% is rounded to the nearest 16:9 integer size (actual scale ~175.18%).
    "8k-6144x3456": PresetConfig(name: "8K-6144", width: 12288, height: 6912, logicalWidth: 6144, logicalHeight: 3456, ppi: 163, hiDPI: true),
    "8k-5760x3240": PresetConfig(name: "8K-5760", width: 11520, height: 6480, logicalWidth: 5760, logicalHeight: 3240, ppi: 163, hiDPI: true),
    "8k-5120x2880": PresetConfig(name: "8K-5120", width: 10240, height: 5760, logicalWidth: 5120, logicalHeight: 2880, ppi: 163, hiDPI: true),
    "8k-4800x2700": PresetConfig(name: "8K-4800", width: 9600, height: 5400, logicalWidth: 4800, logicalHeight: 2700, ppi: 163, hiDPI: true),
    "8k-4384x2466": PresetConfig(name: "8K-4384", width: 8768, height: 4932, logicalWidth: 4384, logicalHeight: 2466, ppi: 163, hiDPI: true),
    "8k-4096x2304": PresetConfig(name: "8K-4096", width: 8192, height: 4608, logicalWidth: 4096, logicalHeight: 2304, ppi: 163, hiDPI: true),
    "8k-3840x2160": PresetConfig(name: "8K-3840", width: 7680, height: 4320, logicalWidth: 3840, logicalHeight: 2160, ppi: 163, hiDPI: true),

    // Samsung G9 57" (7680x2160 native) - Fractional scaling options
    // Scale factor = native / logical, e.g., 7680/5120 = 1.5x
    "g9-57-6144x1728": PresetConfig(name: "G9-57-6144", width: 12288, height: 3456, logicalWidth: 6144, logicalHeight: 1728, ppi: 140, hiDPI: true),  // 1.25x
    "g9-57-5908x1662": PresetConfig(name: "G9-57-5908", width: 11816, height: 3324, logicalWidth: 5908, logicalHeight: 1662, ppi: 140, hiDPI: true),  // 1.3x
    "g9-57-5632x1584": PresetConfig(name: "G9-57-5632", width: 11264, height: 3168, logicalWidth: 5632, logicalHeight: 1584, ppi: 140, hiDPI: true),  // 1.36x
    "g9-57-5486x1543": PresetConfig(name: "G9-57-5486", width: 10972, height: 3086, logicalWidth: 5486, logicalHeight: 1543, ppi: 140, hiDPI: true),  // 1.4x
    "g9-57-5297x1490": PresetConfig(name: "G9-57-5297", width: 10594, height: 2980, logicalWidth: 5297, logicalHeight: 1490, ppi: 140, hiDPI: true),  // 1.45x
    "g9-57-5120x1440": PresetConfig(name: "G9-57-5120", width: 10240, height: 2880, logicalWidth: 5120, logicalHeight: 1440, ppi: 140, hiDPI: true),  // 1.5x (recommended)
    "g9-57-4800x1350": PresetConfig(name: "G9-57-4800", width: 9600, height: 2700, logicalWidth: 4800, logicalHeight: 1350, ppi: 140, hiDPI: true),   // 1.6x
    "g9-57-4389x1234": PresetConfig(name: "G9-57-4389", width: 8778, height: 2468, logicalWidth: 4389, logicalHeight: 1234, ppi: 140, hiDPI: true),   // 1.75x
    "g9-57-3840x1080": PresetConfig(name: "G9-57-3840", width: 7680, height: 2160, logicalWidth: 3840, logicalHeight: 1080, ppi: 140, hiDPI: true),   // 2.0x (native HiDPI)

    // Samsung G9 49" (5120x1440 native) - Fractional scaling options
    "g9-49-4096x1152": PresetConfig(name: "G9-49-4096", width: 8192, height: 2304, logicalWidth: 4096, logicalHeight: 1152, ppi: 109, hiDPI: true),   // 1.25x
    "g9-49-3938x1108": PresetConfig(name: "G9-49-3938", width: 7876, height: 2216, logicalWidth: 3938, logicalHeight: 1108, ppi: 109, hiDPI: true),   // 1.3x
    "g9-49-3840x1080": PresetConfig(name: "G9-49-3840", width: 7680, height: 2160, logicalWidth: 3840, logicalHeight: 1080, ppi: 109, hiDPI: true),   // 1.33x
    "g9-49-3413x960": PresetConfig(name: "G9-49-3413", width: 6826, height: 1920, logicalWidth: 3413, logicalHeight: 960, ppi: 109, hiDPI: true),     // 1.5x (recommended)
    "g9-49-2926x823": PresetConfig(name: "G9-49-2926", width: 5852, height: 1646, logicalWidth: 2926, logicalHeight: 823, ppi: 109, hiDPI: true),     // 1.75x
    "g9-49-2560x720": PresetConfig(name: "G9-49-2560", width: 5120, height: 1440, logicalWidth: 2560, logicalHeight: 720, ppi: 109, hiDPI: true),     // 2.0x (native HiDPI)

    // 34" Ultrawide (3440x1440 native) - Fractional scaling options
    "uw34-2752x1152": PresetConfig(name: "UW34-2752", width: 5504, height: 2304, logicalWidth: 2752, logicalHeight: 1152, ppi: 110, hiDPI: true),     // 1.25x
    "uw34-2646x1108": PresetConfig(name: "UW34-2646", width: 5292, height: 2216, logicalWidth: 2646, logicalHeight: 1108, ppi: 110, hiDPI: true),     // 1.3x
    "uw34-2293x960": PresetConfig(name: "UW34-2293", width: 4586, height: 1920, logicalWidth: 2293, logicalHeight: 960, ppi: 110, hiDPI: true),       // 1.5x (recommended)
    "uw34-1966x823": PresetConfig(name: "UW34-1966", width: 3932, height: 1646, logicalWidth: 1966, logicalHeight: 823, ppi: 110, hiDPI: true),       // 1.75x
    "uw34-1720x720": PresetConfig(name: "UW34-1720", width: 3440, height: 1440, logicalWidth: 1720, logicalHeight: 720, ppi: 110, hiDPI: true),       // 2.0x (native HiDPI)

    // 38" Ultrawide (3840x1600 native) - Fractional scaling options
    "uw38-3072x1280": PresetConfig(name: "UW38-3072", width: 6144, height: 2560, logicalWidth: 3072, logicalHeight: 1280, ppi: 110, hiDPI: true),     // 1.25x
    "uw38-2954x1231": PresetConfig(name: "UW38-2954", width: 5908, height: 2462, logicalWidth: 2954, logicalHeight: 1231, ppi: 110, hiDPI: true),     // 1.3x
    "uw38-2560x1067": PresetConfig(name: "UW38-2560", width: 5120, height: 2134, logicalWidth: 2560, logicalHeight: 1067, ppi: 110, hiDPI: true),     // 1.5x (recommended)
    "uw38-2194x914": PresetConfig(name: "UW38-2194", width: 4388, height: 1828, logicalWidth: 2194, logicalHeight: 914, ppi: 110, hiDPI: true),       // 1.75x
    "uw38-1920x800": PresetConfig(name: "UW38-1920", width: 3840, height: 1600, logicalWidth: 1920, logicalHeight: 800, ppi: 110, hiDPI: true),       // 2.0x (native HiDPI)

    // 4K (3840x2160 native) - Fractional scaling options
    "4k-3072x1728": PresetConfig(name: "4K-3072", width: 6144, height: 3456, logicalWidth: 3072, logicalHeight: 1728, ppi: 163, hiDPI: true),         // 1.25x
    "4k-2954x1662": PresetConfig(name: "4K-2954", width: 5908, height: 3324, logicalWidth: 2954, logicalHeight: 1662, ppi: 163, hiDPI: true),         // 1.3x
    "4k-2560x1440": PresetConfig(name: "4K-2560", width: 5120, height: 2880, logicalWidth: 2560, logicalHeight: 1440, ppi: 163, hiDPI: true),         // 1.5x (recommended)
    "4k-2194x1234": PresetConfig(name: "4K-2194", width: 4388, height: 2468, logicalWidth: 2194, logicalHeight: 1234, ppi: 163, hiDPI: true),         // 1.75x
    "4k-1920x1080": PresetConfig(name: "4K-1920", width: 3840, height: 2160, logicalWidth: 1920, logicalHeight: 1080, ppi: 163, hiDPI: true),         // 2.0x (native HiDPI)
]
