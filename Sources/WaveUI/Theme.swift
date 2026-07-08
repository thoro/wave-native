// Theme.swift — Wave Native visual theme (default dark), pixel-matched to the
// Electron app. Source of truth: docs/STYLE.md. macOS / AppKit only.
//
// NOTE: This compiles on macOS with AppKit (Xcode). It will NOT build on Linux
// (no AppKit). Build + run on the Mac.

import AppKit
import CoreGraphics

private extension NSColor {
    /// #RRGGBB or #RRGGBBAA
    convenience init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xff) / 255
            g = CGFloat((v >> 16) & 0xff) / 255
            b = CGFloat((v >> 8) & 0xff) / 255
            a = CGFloat(v & 0xff) / 255
        } else {
            r = CGFloat((v >> 16) & 0xff) / 255
            g = CGFloat((v >> 8) & 0xff) / 255
            b = CGFloat(v & 0xff) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
    static func white(_ alpha: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }
}

enum Theme {

    // MARK: Surfaces
    static let windowBackground   = NSColor(hex: "#222222")          // rgb(34,34,34)
    static let panelBackground    = NSColor(srgbRed: 31/255, green: 33/255, blue: 31/255, alpha: 0.5)
    static let blockBackground    = NSColor.white(0).blended(withFraction: 0, of: .black) // see blockBg below
    static let blockBg            = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)     // rgba(0,0,0,0.5)
    static let modalBackground    = NSColor(hex: "#232323")
    static let border             = NSColor.white(0.16)
    static let hoverBackground    = NSColor.white(0.10)
    static let highlightBackground = NSColor.white(0.20)

    // MARK: Text
    static let textPrimary        = NSColor(hex: "#f7f7f7")
    static let textSecondary      = NSColor(srgbRed: 195/255, green: 200/255, blue: 194/255, alpha: 1)
    static let textGrey           = NSColor(hex: "#666666")

    // MARK: Accent / status
    static let accent             = NSColor(hex: "#58c142")          // rgb(88,193,66)
    static let accentHover        = NSColor(hex: "#76df60")          // rgb(118,223,96)
    static let error              = NSColor(hex: "#e54d2e")
    static let warning            = NSColor(hex: "#e0b956")
    static let success            = NSColor(hex: "#4e9a06")
    static let link               = NSColor(hex: "#58c142")

    // MARK: Fonts (ship Inter + Hack in the bundle)
    static let uiFont             = NSFont(name: "Inter", size: 14) ?? .systemFont(ofSize: 14)
    static let uiFontMono         = NSFont(name: "Hack", size: 12)  ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
    static let headerFont         = NSFont(name: "Inter", size: 11).map { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) } ?? .boldSystemFont(ofSize: 11)
    static let tabLabelFont       = NSFont(name: "Inter", size: 11) ?? .systemFont(ofSize: 11)
    static let terminalFont       = NSFont(name: "Hack", size: 12)  ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
    static let terminalFontSize: CGFloat = 12
    static let terminalLineHeight: CGFloat = 1.0

    // MARK: Radii / spacing
    /// Large radius (blocks/panes, modals, dropdowns) — pinned to the macOS window corner
    /// radius so a pane flush against the window's rounded corner rounds at the SAME radius
    /// as the content-area mask (border == mask → the border can't be sliced flat), for
    /// single AND split panes alike. One system value for every large rounded corner.
    static var radiusLarge: CGFloat { windowCornerRadius }
    static let radiusMedium: CGFloat = 6   // tabs, buttons, workspace button
    static let radiusSmall: CGFloat  = 4

    /// Approximate macOS window corner radius (no public API exposes the exact value, so
    /// it is keyed to the OS version). Tahoe (macOS 26+) enlarged window corners; earlier
    /// versions are ~10pt. Drives `radiusLarge` and the content-area bottom-corner mask.
    static var windowCornerRadius: CGFloat {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 14 : 10
    }
    static let blockTileGap: CGFloat = 1.5   // visible divider between tiled panes (grab area is inflated separately)
    static let headerGap: CGFloat    = 8
    static let actionGap: CGFloat    = 6

    // MARK: Chrome (upstream values; thoro-fixes used 36/78)
    static let tabBarHeight: CGFloat        = 33
    /// Width of the vertical (left) tab bar when `app:tabbar == "left"`. Wide enough
    /// for a full-width pill row (icon + name + close) plus the switcher/gear chrome.
    static let tabBarLeftWidth: CGFloat     = 180
    /// Per-tab row height when the tab bar is vertical (pills stack as full-width rows).
    static let tabBarLeftRowHeight: CGFloat = 30
    static let widgetBarWidth: CGFloat      = 42   // right-edge launcher strip
    static let tabBarBackground             = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35) // + 20pt backdrop blur
    static let tabBarBlurRadius: CGFloat    = 20
    static let tabWidth: CGFloat            = 130
    static let tabInnerHeight: CGFloat      = 26
    static let tabInnerRadius: CGFloat      = 6
    static let tabActiveFill                = NSColor.white(0.10)   // rgb(from #f7f7f7 / 0.1)
    static let tabActiveLabel               = NSColor(hex: "#ffffff")
    static let tabDivider                   = NSColor.white(0.20)
    static let blockHeaderHeight: CGFloat   = 30
    static let focusedBlockBorderWidth: CGFloat = 2
    static let focusedBlockBorderColor      = accent
    static let trafficLightInset: CGFloat   = 74   // 80 on macOS Tahoe+

    // MARK: Modal shadow
    static let modalShadowColor             = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.8)
    static let modalShadowRadius: CGFloat   = 24
    static let modalShadowOffset            = CGSize(width: 0, height: -8)
}

// MARK: - Terminal default-dark palette (feed to libghostty)
// Order: [black, red, green, yellow, blue, magenta, cyan, white]
enum TerminalTheme {
    static let background  = NSColor(hex: "#000000")
    static let foreground  = NSColor(hex: "#c1c1c1")
    // cursor empty in config -> use foreground; selection empty -> system default
    static let cursor      = foreground

    static let ansi: [NSColor] = [
        NSColor(hex: "#757575"), NSColor(hex: "#cc685c"), NSColor(hex: "#76c266"), NSColor(hex: "#cbca9b"),
        NSColor(hex: "#85aacb"), NSColor(hex: "#cc72ca"), NSColor(hex: "#74a7cb"), NSColor(hex: "#c1c1c1"),
    ]
    static let ansiBright: [NSColor] = [
        NSColor(hex: "#727272"), NSColor(hex: "#cc9d97"), NSColor(hex: "#a3dd97"), NSColor(hex: "#cbcaaa"),
        NSColor(hex: "#9ab6cb"), NSColor(hex: "#cc8ecb"), NSColor(hex: "#b7b8cb"), NSColor(hex: "#f0f0f0"),
    ]
    // cursorStyle = block, cursorBlink = false (settings.json)
}
