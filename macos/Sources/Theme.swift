import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    init(hslHue: Double, saturation: Double, lightness: Double) {
        let h = ((hslHue.truncatingRemainder(dividingBy: 360.0)) + 360.0).truncatingRemainder(dividingBy: 360.0) / 360.0
        let s = max(0.0, min(1.0, saturation / 100.0))
        let l = max(0.0, min(1.0, lightness / 100.0))

        if s == 0 {
            self.init(.sRGB, red: l, green: l, blue: l, opacity: 1.0)
            return
        }
        let q = l < 0.5 ? l * (1.0 + s) : l + s - l * s
        let p = 2.0 * l - q
        func hue2rgb(_ tIn: Double) -> Double {
            var t = tIn
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6.0 { return p + (q - p) * 6.0 * t }
            if t < 1.0 / 2.0 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6.0 }
            return p
        }
        self.init(.sRGB, red: hue2rgb(h + 1.0 / 3.0), green: hue2rgb(h), blue: hue2rgb(h - 1.0 / 3.0), opacity: 1.0)
    }
}

struct PulseTheme {
    let isLight: Bool

    var cardBg: Color { isLight ? Color(hex: 0xFFFFFF) : Color(hex: 0x1A2222) }
    var elevatedBg: Color { isLight ? Color(hex: 0xF3FAF9) : Color.white.opacity(0.038) }
    var rowBg: Color { isLight ? Color(hex: 0xF6FBFA) : Color.white.opacity(0.03) }
    var border: Color { isLight ? Color(hex: 0xDCE7E5) : Color.white.opacity(0.09) }
    var divider: Color { isLight ? Color(hex: 0xE2ECEA) : Color.white.opacity(0.07) }
    var trackBg: Color { isLight ? Color(hex: 0xE2ECEA) : Color.white.opacity(0.07) }

    var title: Color { isLight ? Color(hex: 0x0F172A) : Color(hex: 0xECFEFF) }
    var primaryText: Color { isLight ? Color(hex: 0x1E293B) : Color(hex: 0xE2F3F2) }
    var secondaryText: Color { isLight ? Color(hex: 0x475569) : Color(hex: 0x94A3A8) }
    var mutedText: Color { isLight ? Color(hex: 0x64748B) : Color(hex: 0x76898E) }

    var accent: Color { isLight ? Color(hex: 0x0F766E) : Color(hex: 0x5EEAD4) }
    var accentBg: Color { isLight ? Color(hex: 0x0D9488, alpha: 0.12) : Color(hex: 0x14B8A6, alpha: 0.20) }
    var accentBorder: Color { isLight ? Color(hex: 0x0D9488, alpha: 0.28) : Color(hex: 0x5EEAD4, alpha: 0.30) }

    var desktopColor: Color { isLight ? Color(hex: 0x0D9488) : Color(hex: 0x14B8A6) }
    var cliColor: Color { isLight ? Color(hex: 0x2563EB) : Color(hex: 0x60A5FA) }
    var inputTokenColor: Color { isLight ? Color(hex: 0x0284C7) : Color(hex: 0x38BDF8) }
    var outputTokenColor: Color { isLight ? Color(hex: 0x16A34A) : Color(hex: 0x34D399) }

    var tooltipBg: Color { isLight ? Color(hex: 0xFFFFFF) : Color(hex: 0x243030) }
    var tooltipBorder: Color { isLight ? Color(hex: 0x0F172A, alpha: 0.14) : Color.white.opacity(0.14) }
    var cellHoverOutline: Color { isLight ? Color(hex: 0x0F172A, alpha: 0.55) : Color.white.opacity(0.65) }

    var heatmapLevels: [Color] {
        if isLight {
            return [
                Color(hex: 0xEAEEF0),
                Color(hex: 0x99F6E4),
                Color(hex: 0x2DD4BF),
                Color(hex: 0x0D9488),
                Color(hex: 0x115E59),
            ]
        }
        return [
            Color(hex: 0x232C2C),
            Color(hex: 0x134E4A),
            Color(hex: 0x0F766E),
            Color(hex: 0x14B8A6),
            Color(hex: 0x5EEAD4),
        ]
    }

    func heatmapColor(for totalTokens: Double, bounds: HeatScaleBounds) -> Color {
        let lv = heatmapLevels
        return lv[bounds.level(for: totalTokens)]
    }

    static func resolve(preference: ThemePreference, systemColorScheme: ColorScheme) -> PulseTheme {
        switch preference {
        case .light: return PulseTheme(isLight: true)
        case .dark: return PulseTheme(isLight: false)
        case .system: return PulseTheme(isLight: systemColorScheme == .light)
        }
    }
}

struct ModelColorPalette {
    private static let curatedHexes: [UInt32] = [
        0x14B8A6, // Jade Teal
        0x38BDF8, // Sky Cyan
        0xFBBF24, // Amber Gold
        0x34D399, // Mint Emerald
        0xFB923C, // Warm Orange
        0x06B6D4, // Glacier Cyan
        0x60A5FA, // Azure Blue
        0xF87171, // Coral Red
    ]
    private static let otherColor = Color(hex: 0x64748B)

    private var colorMap: [String: Color] = [:]

    init(stats: ActivityStats) {
        var totals: [String: Double] = [:]
        for (name, usage) in stats.allTime.models where usage.totalTokens > 0 {
            totals[name, default: 0] += usage.totalTokens
        }
        for day in stats.days.values {
            for (name, usage) in day.models where usage.totalTokens > 0 && totals[name] == nil {
                totals[name, default: 0] += usage.totalTokens
            }
        }
        let sortedNamed = totals
            .filter { $0.key != "其他模型" && $0.key != "其他" }
            .sorted { a, b in
                if a.value != b.value { return a.value > b.value }
                return a.key < b.key
            }

        colorMap["其他模型"] = Self.otherColor
        colorMap["其他"] = Self.otherColor

        for (idx, item) in sortedNamed.enumerated() {
            if idx < Self.curatedHexes.count {
                colorMap[item.key] = Color(hex: Self.curatedHexes[idx])
            } else {
                colorMap[item.key] = Self.nonPurpleColor(seed: item.key, index: idx)
            }
        }
    }

    func color(for modelName: String) -> Color {
        let key = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty || key == "其他模型" || key == "其他" {
            return Self.otherColor
        }
        if let c = colorMap[key] {
            return c
        }
        return Self.nonPurpleColor(seed: key, index: colorMap.count)
    }

    private static func nonPurpleColor(seed: String, index: Int) -> Color {
        let h = stringHash(seed)
        let raw = Double(index) * 137.508 + Double(abs(h % 60))
        // Keep generated hues strictly within warm-orange -> green -> cyan -> blue [15°, 235°)
        let hue = 15.0 + raw.truncatingRemainder(dividingBy: 220.0)
        return Color(hslHue: hue, saturation: 76, lightness: 60)
    }

    private static func stringHash(_ str: String) -> Int32 {
        var hash: Int32 = 0
        for codeUnit in str.utf16 {
            hash = (hash &<< 5) &- hash &+ Int32(codeUnit)
        }
        return hash
    }
}
