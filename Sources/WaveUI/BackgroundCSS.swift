// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pure (AppKit-free) parsing of the subset of CSS `background` values that Wave's tab
/// background feature uses. Electron applies the raw `bg` meta string straight to the CSS
/// `background` shorthand (see frontend `computeBgStyleFromMeta`); we reproduce the common
/// cases — solid color, linear/radial gradient, and `url(...)` image — so the native
/// renderer matches. Kept value-only so it is unit-testable without a window.

/// A straight RGBA color, all components normalized to 0...1.
public struct RGBAColor: Equatable, Sendable {
    public let r: Double
    public let g: Double
    public let b: Double
    public let a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

/// One gradient color stop. `location` is the 0...1 position when given explicitly, else
/// nil (the renderer spaces auto stops evenly, matching CSS).
public struct GradientStop: Equatable, Sendable {
    public let color: RGBAColor
    public let location: Double?

    public init(color: RGBAColor, location: Double? = nil) {
        self.color = color
        self.location = location
    }
}

/// A parsed `linear-gradient(...)`. `angleDegrees` follows CSS semantics: 0 points up
/// ("to top"), 90 right, 180 down, 270 left.
public struct LinearGradientSpec: Equatable, Sendable {
    public let angleDegrees: Double
    public let stops: [GradientStop]
}

/// What a single CSS background layer resolves to. `unknown` covers values we do not model
/// (so the renderer can skip them rather than draw something wrong).
public enum BackgroundKind: Equatable, Sendable {
    case color(RGBAColor)
    case linearGradient(LinearGradientSpec)
    case radialGradient([GradientStop])
    case image(url: String)
    case unknown
}

public enum BackgroundCSS {
    /// Split a CSS value on `separator` at the TOP level only, so separators inside
    /// `func(...)` (e.g. the commas in `rgba(...)` or between a gradient's stops) are kept
    /// with their layer. This is how a multi-layer `background` is broken into layers.
    public static func splitTopLevel(_ s: String, separator: Character = ",") -> [String] {
        var out: [String] = []
        var depth = 0
        var current = ""
        for ch in s {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if ch == separator && depth == 0 {
                out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                continue
            }
            current.append(ch)
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { out.append(last) }
        return out
    }

    /// Break a full `bg` value into its CSS background layers (first layer is painted on
    /// top, per CSS) and classify each.
    public static func parseLayers(_ value: String) -> [BackgroundKind] {
        splitTopLevel(value).map { classify($0) }
    }

    /// Classify a single (already top-level-split) background layer.
    public static func classify(_ value: String) -> BackgroundKind {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = v.lowercased()
        if lower.hasPrefix("linear-gradient(") {
            if let g = parseLinearGradient(v) { return .linearGradient(g) }
            return .unknown
        }
        if lower.hasPrefix("radial-gradient(") {
            if let stops = parseRadialGradient(v) { return .radialGradient(stops) }
            return .unknown
        }
        if lower.hasPrefix("url(") {
            if let url = parseURL(v) { return .image(url: url) }
            return .unknown
        }
        if let color = parseColor(v) { return .color(color) }
        return .unknown
    }

    /// Pull the (unquoted) target out of a `url(...)` token.
    public static func parseURL(_ value: String) -> String? {
        guard let inner = functionArgs(value, name: "url") else { return nil }
        var s = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
            s = String(s.dropFirst().dropLast())
        }
        return s.isEmpty ? nil : s
    }

    // MARK: - Gradients

    public static func parseLinearGradient(_ value: String) -> LinearGradientSpec? {
        guard let inner = functionArgs(value, name: "linear-gradient") else { return nil }
        var parts = splitTopLevel(inner)
        guard !parts.isEmpty else { return nil }
        var angle = 180.0  // CSS default direction is "to bottom".
        if let parsed = parseAngle(parts[0]) {
            angle = parsed
            parts.removeFirst()
        }
        let stops = parts.compactMap { parseStop($0) }
        guard !stops.isEmpty else { return nil }
        return LinearGradientSpec(angleDegrees: angle, stops: stops)
    }

    /// KISS: a radial gradient is reduced to its color stops (centered, drawn as a circle).
    /// Any leading shape/size/position token (e.g. `circle at 70% 70%`) is dropped — noted
    /// as an approximation.
    public static func parseRadialGradient(_ value: String) -> [GradientStop]? {
        guard let inner = functionArgs(value, name: "radial-gradient") else { return nil }
        var parts = splitTopLevel(inner)
        guard !parts.isEmpty else { return nil }
        // Drop a non-color configuration head (contains "circle", "ellipse", "at", or a
        // bare size) so only stops remain.
        if let first = parts.first, isRadialConfigHead(first) {
            parts.removeFirst()
        }
        let stops = parts.compactMap { parseStop($0) }
        return stops.isEmpty ? nil : stops
    }

    private static func isRadialConfigHead(_ s: String) -> Bool {
        let lower = s.lowercased()
        if parseStop(s) != nil && !lower.contains(" at ") && !lower.hasPrefix("circle")
            && !lower.hasPrefix("ellipse") {
            return false
        }
        return lower.contains("circle") || lower.contains("ellipse") || lower.contains(" at ")
            || lower.hasPrefix("at ")
    }

    /// Parse a gradient direction/angle token: `Ndeg`, `Nturn`, `Nrad`, or a `to <side>`
    /// keyword. Returns nil if the token is actually a color stop.
    public static func parseAngle(_ token: String) -> Double? {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasPrefix("to ") {
            let dirs = Set(t.dropFirst(3).split(separator: " ").map(String.init))
            let up = dirs.contains("top")
            let down = dirs.contains("bottom")
            let left = dirs.contains("left")
            let right = dirs.contains("right")
            if up && right { return 45 }
            if down && right { return 135 }
            if down && left { return 225 }
            if up && left { return 315 }
            if up { return 0 }
            if right { return 90 }
            if down { return 180 }
            if left { return 270 }
            return nil
        }
        if t.hasSuffix("deg"), let v = Double(t.dropLast(3)) { return normalizeAngle(v) }
        if t.hasSuffix("turn"), let v = Double(t.dropLast(4)) { return normalizeAngle(v * 360) }
        if t.hasSuffix("grad"), let v = Double(t.dropLast(4)) { return normalizeAngle(v * 0.9) }
        if t.hasSuffix("rad"), let v = Double(t.dropLast(3)) { return normalizeAngle(v * 180 / .pi) }
        return nil
    }

    private static func normalizeAngle(_ a: Double) -> Double {
        let m = a.truncatingRemainder(dividingBy: 360)
        return m < 0 ? m + 360 : m
    }

    /// Parse a `<color> [<position%>]` stop.
    public static func parseStop(_ token: String) -> GradientStop? {
        let s = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var colorStr = s
        var positionStr: String? = nil
        if let parenClose = matchingParenRange(s) {
            // Functional color like rgba(...): the position (if any) follows the ")".
            colorStr = String(s[..<parenClose.upperBound])
            let rest = String(s[parenClose.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { positionStr = rest }
        } else if let spaceIdx = s.firstIndex(of: " ") {
            colorStr = String(s[..<spaceIdx])
            positionStr = String(s[s.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let color = parseColor(colorStr) else { return nil }
        var location: Double? = nil
        if let p = positionStr, p.hasSuffix("%"), let v = Double(p.dropLast()) {
            location = v / 100
        }
        return GradientStop(color: color, location: location)
    }

    // MARK: - Colors

    public static func parseColor(_ value: String) -> RGBAColor? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.hasPrefix("#") { return parseHex(v) }
        let lower = v.lowercased()
        if lower.hasPrefix("rgb") { return parseRGBFunction(v) }
        if lower.hasPrefix("hsl") { return parseHSLFunction(v) }
        return namedColors[lower]
    }

    public static func parseHex(_ value: String) -> RGBAColor? {
        var hex = value
        hex.removeFirst()
        func comp(_ s: Substring) -> Double? {
            guard let i = Int(s, radix: 16) else { return nil }
            return Double(i) / 255
        }
        let chars = Array(hex)
        if chars.count == 3 || chars.count == 4 {
            // Shorthand: each nibble is doubled.
            func dup(_ c: Character) -> Double? { comp("\(c)\(c)"[...]) }
            guard let r = dup(chars[0]), let g = dup(chars[1]), let b = dup(chars[2]) else { return nil }
            let a = chars.count == 4 ? (dup(chars[3]) ?? 1) : 1
            return RGBAColor(r: r, g: g, b: b, a: a)
        }
        if chars.count == 6 || chars.count == 8 {
            let s = hex[...]
            func at(_ i: Int) -> Substring { s[s.index(s.startIndex, offsetBy: i)..<s.index(s.startIndex, offsetBy: i + 2)] }
            guard let r = comp(at(0)), let g = comp(at(2)), let b = comp(at(4)) else { return nil }
            let a = chars.count == 8 ? (comp(at(6)) ?? 1) : 1
            return RGBAColor(r: r, g: g, b: b, a: a)
        }
        return nil
    }

    private static func parseRGBFunction(_ value: String) -> RGBAColor? {
        guard let inner = parenContents(value) else { return nil }
        // Accept both comma and whitespace/slash separators.
        let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count >= 3 else { return nil }
        func channel(_ s: String) -> Double? {
            if s.hasSuffix("%"), let v = Double(s.dropLast()) { return v / 100 }
            guard let v = Double(s) else { return nil }
            return v / 255
        }
        guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
        var a = 1.0
        if parts.count >= 4 {
            let s = parts[3]
            if s.hasSuffix("%"), let v = Double(s.dropLast()) { a = v / 100 } else if let v = Double(s) { a = v }
        }
        return RGBAColor(r: clamp01(r), g: clamp01(g), b: clamp01(b), a: clamp01(a))
    }

    private static func parseHSLFunction(_ value: String) -> RGBAColor? {
        guard let inner = parenContents(value) else { return nil }
        let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count >= 3 else { return nil }
        func num(_ s: String, suffix: String) -> Double? {
            var t = s
            if t.hasSuffix("deg") { t = String(t.dropLast(3)) }
            if t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
            return Double(t)
        }
        guard let h = num(parts[0], suffix: ""), let s = num(parts[1], suffix: "%"),
              let l = num(parts[2], suffix: "%") else { return nil }
        var a = 1.0
        if parts.count >= 4 {
            let av = parts[3]
            if av.hasSuffix("%"), let v = Double(av.dropLast()) { a = v / 100 } else if let v = Double(av) { a = v }
        }
        let rgb = hslToRGB(h: h, s: s / 100, l: l / 100)
        return RGBAColor(r: rgb.0, g: rgb.1, b: rgb.2, a: clamp01(a))
    }

    static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        var r = 0.0, g = 0.0, b = 0.0
        switch hp {
        case 0..<1: (r, g, b) = (c, x, 0)
        case 1..<2: (r, g, b) = (x, c, 0)
        case 2..<3: (r, g, b) = (0, c, x)
        case 3..<4: (r, g, b) = (0, x, c)
        case 4..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = l - c / 2
        return (clamp01(r + m), clamp01(g + m), clamp01(b + m))
    }

    // MARK: - Small helpers

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    /// Contents of the outermost `(...)` in a function expression.
    private static func parenContents(_ s: String) -> String? {
        guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close else { return nil }
        return String(s[s.index(after: open)..<close])
    }

    /// Args of `name(...)`, only if the expression starts with that function name.
    private static func functionArgs(_ s: String, name: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.lowercased().hasPrefix(name.lowercased() + "(") else { return nil }
        return parenContents(t)
    }

    /// Range covering the FIRST balanced `(...)` group starting at the first `(`.
    private static func matchingParenRange(_ s: String) -> Range<String.Index>? {
        guard let open = s.firstIndex(of: "(") else { return nil }
        var depth = 0
        var i = open
        while i < s.endIndex {
            let ch = s[i]
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth == 0 { return open..<s.index(after: i) }
            }
            i = s.index(after: i)
        }
        return nil
    }
}

/// A small CSS named-color table (the common names that appear in Wave's preset
/// backgrounds and typical user configs). Not the full CSS list — unknown names fall
/// through to `unknown` so the renderer skips them.
private let namedColors: [String: RGBAColor] = {
    func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> RGBAColor {
        RGBAColor(r: r / 255, g: g / 255, b: b / 255, a: a)
    }
    return [
        "transparent": RGBAColor(r: 0, g: 0, b: 0, a: 0),
        "black": c(0, 0, 0), "white": c(255, 255, 255), "red": c(255, 0, 0),
        "green": c(0, 128, 0), "lime": c(0, 255, 0), "blue": c(0, 0, 255),
        "yellow": c(255, 255, 0), "cyan": c(0, 255, 255), "aqua": c(0, 255, 255),
        "magenta": c(255, 0, 255), "fuchsia": c(255, 0, 255), "gray": c(128, 128, 128),
        "grey": c(128, 128, 128), "silver": c(192, 192, 192), "maroon": c(128, 0, 0),
        "olive": c(128, 128, 0), "teal": c(0, 128, 128), "navy": c(0, 0, 128),
        "purple": c(128, 0, 128), "orange": c(255, 165, 0), "pink": c(255, 192, 203),
        "brown": c(165, 42, 42), "gold": c(255, 215, 0), "indigo": c(75, 0, 130),
        "violet": c(238, 130, 238), "coral": c(255, 127, 80), "salmon": c(250, 128, 114),
        "khaki": c(240, 230, 140), "crimson": c(220, 20, 60), "turquoise": c(64, 224, 208),
        "skyblue": c(135, 206, 235), "tomato": c(255, 99, 71),
    ]
}()
