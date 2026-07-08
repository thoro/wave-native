// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — the right-edge widget launcher strip (Electron `workspace/widgets.tsx`).
// A fixed-width vertical column of image-only buttons, one per `WidgetItem`; each
// click creates a new block of the widget's type in the active tab. Dark chrome to
// match the tab strip / workspace switcher.

import AppKit
import WaveCore

/// The vertical launcher column pinned to the window's right edge.
final class WidgetBarView: NSView {
    /// Fired when a widget button is clicked: carries the block `meta` to create and
    /// whether it should open magnified. Wired by `WaveWindowController` to
    /// `AppCoordinator.createWidgetBlock`.
    var onSelect: ((MetaMapType, Bool) -> Void)?

    private let stack = NSStackView()

    /// Drop the strip's own dark fill while the active tab has a background so
    /// the root-level background view tints it like the rest of the chrome.
    func setTabBackgroundActive(_ active: Bool) {
        layer?.backgroundColor = (active ? NSColor.clear : Theme.tabBarBackground).cgColor
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.tabBarBackground.cgColor
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private func setup() {
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// Rebuild the button column from `items` (already sorted + hidden-filtered by the
    /// coordinator).
    func setItems(_ items: [WidgetItem]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            stack.addArrangedSubview(makeButton(for: item))
        }
        isHidden = items.isEmpty
        needsLayout = true
    }

    private func makeButton(for item: WidgetItem) -> NSView {
        let button = WidgetButton { [weak self] in self?.onSelect?(item.blockDefMeta, item.magnified) }
        button.image = WorkspaceSwitcherView.iconImage(forWaveIcon: item.icon)
        button.contentTintColor = (item.color.flatMap(WorkspaceSwitcherView.color(from:))) ?? Theme.textSecondary
        button.toolTip = item.label ?? item.icon
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 34),
            button.heightAnchor.constraint(equalToConstant: 34),
        ])
        return button
    }
}

/// A borderless, image-only, hover-highlighting launcher button.
final class WidgetButton: NSButton {
    private let onTap: () -> Void
    private var trackingArea: NSTrackingArea?

    init(action: @escaping () -> Void) {
        self.onTap = action
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        title = ""
        wantsLayer = true
        layer?.cornerRadius = Theme.radiusMedium
        target = self
        self.action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { onTap() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = Theme.hoverBackground.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
}
