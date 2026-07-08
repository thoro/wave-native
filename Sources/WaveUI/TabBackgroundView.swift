// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// The resolved per-tab background, threaded from the coordinator (active tab's `bg*`
/// meta, or a named `tab:background` preset) to the chrome. Mirrors Electron's
/// `computeBgStyleFromMeta` inputs: the `bg` CSS shorthand plus `bg:opacity` and
/// `bg:blendmode`.
public struct TabBackgroundConfig: Equatable, Sendable {
    public let bg: String
    public let opacity: Double?
    public let blendMode: String?

    public init(bg: String, opacity: Double?, blendMode: String?) {
        self.bg = bg
        self.opacity = opacity
        self.blendMode = blendMode
    }
}

/// A named tab-background preset from the config `backgrounds` map (e.g. `bg@blue`),
/// surfaced in the tab pill's "Background" submenu. `key` is written to a tab's
/// `tab:background` meta; `displayName`/`order` come from the preset's `display:name`
/// and `display:order`. Mirrors how `TermThemeMenuItem` carries a config-defined choice
/// to a native menu.
public struct TabBackgroundPreset: Equatable, Sendable {
    public let key: String
    public let displayName: String
    public let order: Double

    public init(key: String, displayName: String, order: Double) {
        self.key = key
        self.displayName = displayName
        self.order = order
    }
}

/// Renders a tab background (color / gradient / image) behind the panes. Inserted as the
/// bottom-most subview of the content area so translucent panes and the inter-tile gaps
/// reveal it. Pointer-transparent — it never intercepts clicks meant for the panes.
final class TabBackgroundView: NSView {
    /// Process-wide image cache keyed by the resolved URL string. Backgrounds are reused
    /// across tabs/windows, so decoding once avoids re-reading large files on every switch.
    private static var imageCache: [String: NSImage] = [:]

    /// Electron's app background defaults the element opacity to 0.5 when a `bg` is set but
    /// no explicit `bg:opacity` is given (see `AppBackground` passing `0.5`).
    private static let defaultOpacity: Float = 0.5

    /// Token used to drop a stale async image load if the config changed meanwhile.
    private var loadToken = 0

    var config: TabBackgroundConfig? {
        didSet {
            if config != oldValue { applyConfig() }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Pointer-events-none: never steal clicks from the panes above the (clear) regions.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard let sublayers = layer?.sublayers else { return }
        // Keep every background sublayer filling the view; gradients/images must track
        // resize without implicit animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sub in sublayers { sub.frame = bounds }
        CATransaction.commit()
    }

    private func applyConfig() {
        loadToken += 1
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let config, !config.bg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No background: stay clear so the content area's own window background shows.
            layer?.opacity = 1
            return
        }
        layer?.opacity = config.opacity.map { Float(max(0, min(1, $0))) } ?? Self.defaultOpacity

        let layers = BackgroundCSS.parseLayers(config.bg)
        // CSS paints the FIRST background layer on top; CALayer paints later-added
        // sublayers on top — so add the layers in reverse to match the CSS stack.
        for kind in layers.reversed() {
            guard let sub = makeLayer(for: kind) else { continue }
            sub.frame = bounds
            layer?.addSublayer(sub)
        }
    }

    private func makeLayer(for kind: BackgroundKind) -> CALayer? {
        switch kind {
        case .color(let rgba):
            let l = CALayer()
            l.backgroundColor = Self.cgColor(rgba)
            return l
        case .linearGradient(let spec):
            return Self.makeGradientLayer(stops: spec.stops, angleDegrees: spec.angleDegrees, radial: false)
        case .radialGradient(let stops):
            return Self.makeGradientLayer(stops: stops, angleDegrees: 0, radial: true)
        case .image(let url):
            return makeImageLayer(url: url)
        case .unknown:
            return nil
        }
    }

    private func makeImageLayer(url: String) -> CALayer? {
        let l = CALayer()
        l.contentsGravity = .resizeAspectFill
        l.masksToBounds = true
        if let cached = Self.imageCache[url] {
            l.contents = cached
            return l
        }
        let token = loadToken
        Self.loadImage(url: url) { [weak self, weak l] image in
            guard let self, let l, self.loadToken == token, let image else { return }
            Self.imageCache[url] = image
            l.contents = image
        }
        return l
    }

    // MARK: - Pure-ish builders

    private static func cgColor(_ c: RGBAColor) -> CGColor {
        CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    static func makeGradientLayer(stops: [GradientStop], angleDegrees: Double, radial: Bool) -> CAGradientLayer? {
        guard !stops.isEmpty else { return nil }
        let g = CAGradientLayer()
        g.type = radial ? .radial : .axial
        g.colors = stops.map { cgColor($0.color) }
        let locations = resolveLocations(stops)
        g.locations = locations.map { NSNumber(value: $0) }
        if radial {
            // KISS: centered circle filling the view; CSS shape/position is approximated.
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 1.0, y: 1.0)
        } else {
            let (start, end) = axialPoints(angleDegrees: angleDegrees)
            g.startPoint = start
            g.endPoint = end
        }
        return g
    }

    /// Evenly space any stops that lack an explicit position (matching CSS auto-placement),
    /// keeping the sequence non-decreasing.
    static func resolveLocations(_ stops: [GradientStop]) -> [Double] {
        let n = stops.count
        if n == 1 { return [0] }
        var out = [Double?](repeating: nil, count: n)
        for (i, s) in stops.enumerated() { out[i] = s.location }
        if out[0] == nil { out[0] = 0 }
        if out[n - 1] == nil { out[n - 1] = 1 }
        var i = 0
        while i < n {
            if out[i] != nil { i += 1; continue }
            var j = i
            while j < n && out[j] == nil { j += 1 }
            let prev = out[i - 1] ?? 0
            let next = out[j] ?? 1
            let span = Double(j - (i - 1))
            for k in i..<j { out[k] = prev + (next - prev) * Double(k - (i - 1)) / span }
            i = j
        }
        // Clamp to monotonic non-decreasing for CAGradientLayer stability.
        var result = out.map { $0 ?? 0 }
        for k in 1..<result.count where result[k] < result[k - 1] { result[k] = result[k - 1] }
        return result
    }

    /// Convert a CSS gradient angle (0 = up, 90 = right) into CAGradientLayer start/end
    /// unit points. CAGradientLayer's coordinate space has (0,0) at the bottom-left, so an
    /// upward CSS gradient maps to +y here. The line is centered and projected to the unit
    /// box edges (approximate for non-axis angles — good enough for the common presets).
    static func axialPoints(angleDegrees: Double) -> (CGPoint, CGPoint) {
        let rad = angleDegrees * .pi / 180
        let dx = sin(rad)
        let dy = cos(rad)
        let start = CGPoint(x: 0.5 - dx * 0.5, y: 0.5 - dy * 0.5)
        let end = CGPoint(x: 0.5 + dx * 0.5, y: 0.5 + dy * 0.5)
        return (start, end)
    }

    // MARK: - Image loading

    /// Resolve `url` and deliver an NSImage (or nil) on the main queue. Supports local file
    /// paths, `file://`, `data:` URIs, and remote `http(s)` URLs — the schemes Electron's
    /// `processBackgroundUrls` allows.
    static func loadImage(url: String, completion: @escaping (NSImage?) -> Void) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("data:") {
            let image = dataURLImage(trimmed)
            DispatchQueue.main.async { completion(image) }
            return
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"), let u = URL(string: trimmed) {
            URLSession.shared.dataTask(with: u) { data, _, _ in
                let image = data.flatMap { NSImage(data: $0) }
                DispatchQueue.main.async { completion(image) }
            }.resume()
            return
        }
        let path: String
        if trimmed.hasPrefix("file://") {
            path = URL(string: trimmed)?.path ?? String(trimmed.dropFirst("file://".count))
        } else if trimmed.hasPrefix("~/") {
            path = (trimmed as NSString).expandingTildeInPath
        } else {
            path = trimmed
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let image = NSImage(contentsOfFile: path)
            DispatchQueue.main.async { completion(image) }
        }
    }

    private static func dataURLImage(_ s: String) -> NSImage? {
        guard let comma = s.firstIndex(of: ","), s.lowercased().contains(";base64") else { return nil }
        let b64 = String(s[s.index(after: comma)...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }
}
