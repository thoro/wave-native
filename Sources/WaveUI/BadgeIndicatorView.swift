// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — renders `wsh badge` badges: the lead badge as an SF Symbol in its colour,
// plus up to two small dots for the runners-up (Electron `TabBadges`). Used by the
// tab pill and the block header.

import AppKit
import WaveCore

final class BadgeIndicatorView: NSView {
    /// Electron's default badge colour (`#fbbf24`, tailwind amber-400).
    static let defaultColor = NSColor(srgbRed: 0xfb / 255.0, green: 0xbf / 255.0, blue: 0x24 / 255.0, alpha: 1)
    static let maxExtraDots = 2
    private static let dotSize: CGFloat = 4

    private let iconView = NSImageView()
    private let dotStack = NSStackView()
    private let pointSize: CGFloat

    /// Sorted, lead first. Empty hides the view.
    var badges: [Badge] = [] {
        didSet { if oldValue != badges { refresh() } }
    }

    init(pointSize: CGFloat) {
        self.pointSize = pointSize
        super.init(frame: .zero)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        dotStack.orientation = .vertical
        dotStack.spacing = 2
        dotStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotStack)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: pointSize + 2),
            iconView.heightAnchor.constraint(equalToConstant: pointSize + 2),
            dotStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 2),
            dotStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: iconView.heightAnchor),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Purely decorative: clicks fall through to the pill/header underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func color(for badge: Badge) -> NSColor {
        guard let css = badge.color, let c = BackgroundCSS.parseColor(css) else { return defaultColor }
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    static func image(for badge: Badge, pointSize: CGFloat) -> NSImage? {
        // `circle-small` (the wsh default) is a dot, not a full circle.
        let size = badge.icon == "circle-small" || badge.icon.isEmpty ? pointSize * 0.6 : pointSize
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        let name = WorkspaceSwitcherView.symbolName(forWaveIcon: badge.icon.isEmpty ? "circle-small" : badge.icon)
        return NSImage(systemSymbolName: name, accessibilityDescription: badge.icon)?.withSymbolConfiguration(config)
    }

    private func refresh() {
        isHidden = badges.isEmpty
        dotStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let lead = badges.first else { return }
        iconView.image = Self.image(for: lead, pointSize: pointSize)
        iconView.contentTintColor = Self.color(for: lead)
        for extra in badges.dropFirst().prefix(Self.maxExtraDots) {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = Self.dotSize / 2
            dot.layer?.backgroundColor = Self.color(for: extra).cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
                dot.heightAnchor.constraint(equalToConstant: Self.dotSize),
            ])
            dotStack.addArrangedSubview(dot)
        }
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }
}
