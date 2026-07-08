// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveTerminal — pure value types + helpers for the live-applied terminal
// appearance settings (`term:fontsize` / `term:fontfamily` / `term:transparency`
// / `term:theme`). Kept free of libghostty so the font/colour math is unit-testable
// without a live `GhosttyTerminal`; `GhosttyTerminalView` consumes them and pushes
// the palette into libghostty via `GHOSTTY_TERMINAL_OPT_COLOR_*`.

import Foundation

/// A 24-bit RGB colour, the unit a terminal theme resolves to. Parsed from the
/// `#rrggbb` hex strings Wave ships in `termthemes` (`pkg/wconfig/settingsconfig.go`).
public struct TermRGB: Equatable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Parse `#rrggbb` (or `rrggbb`). Returns nil for empty/invalid input so callers
    /// fall back to libghostty's built-in colour for that slot.
    public static func fromHex(_ hex: String?) -> TermRGB? {
        guard var s = hex, !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return TermRGB(
            r: UInt8((v >> 16) & 0xff),
            g: UInt8((v >> 8) & 0xff),
            b: UInt8(v & 0xff))
    }
}

/// A resolved terminal colour palette: the 16 ANSI colours (indices 0–15) plus the
/// default foreground/background, cursor, and selection. A `nil` slot means "leave
/// libghostty's default" — so a partial theme (e.g. only `background`) still works.
public struct TerminalColorPalette: Equatable, Sendable {
    /// ANSI 0–15 in order: black, red, green, yellow, blue, magenta, cyan, white,
    /// then the bright variants. A `nil` entry keeps the default for that index.
    public let ansi: [TermRGB?]
    public let foreground: TermRGB?
    public let background: TermRGB?
    public let cursor: TermRGB?
    public let selection: TermRGB?

    public init(
        ansi: [TermRGB?] = [],
        foreground: TermRGB? = nil,
        background: TermRGB? = nil,
        cursor: TermRGB? = nil,
        selection: TermRGB? = nil
    ) {
        self.ansi = ansi
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
    }

    /// True when the palette overrides nothing — `GhosttyTerminalView` then leaves
    /// libghostty's built-in colours untouched (default-theme / unknown-theme case).
    public var isEmpty: Bool {
        ansi.allSatisfy { $0 == nil } && foreground == nil && background == nil
            && cursor == nil && selection == nil
    }
}

#if canImport(AppKit)
import AppKit

/// Derives the terminal font + background alpha from the live `term:*` settings.
/// Pure (no view state) so the mapping is unit-testable.
public enum TerminalFontSettings {
    /// Wave's default terminal font (STYLE §2) and size.
    public static let defaultFamily = "Hack"
    public static let defaultSize: CGFloat = 12

    /// Build the base terminal font from the (optional) family + size settings,
    /// falling back to Hack 12 and then a monospaced system font.
    public static func font(family: String?, size: Double?) -> NSFont {
        let pts = CGFloat(size ?? Double(defaultSize))
        let resolved = (pts > 0) ? pts : defaultSize
        if let family, !family.isEmpty, let f = NSFont(name: family, size: resolved) {
            return f
        }
        return NSFont(name: defaultFamily, size: resolved)
            ?? .monospacedSystemFont(ofSize: resolved, weight: .regular)
    }

    /// Map `term:transparency` (0 = opaque … 1 = fully transparent) to a background
    /// alpha (1 … 0). Clamped; nil/absent ⇒ opaque.
    public static func backgroundAlpha(transparency: Double?) -> CGFloat {
        let t = Swift.min(1.0, Swift.max(0.0, transparency ?? 0))
        return CGFloat(1.0 - t)
    }
}
#endif
