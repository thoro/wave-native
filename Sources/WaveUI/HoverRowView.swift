// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — hover tracking for rows inside a scrolling list. Plain tracking-area
// enter/exit is unreliable while the list scrolls under a stationary cursor:
// AppKit delivers `mouseEntered` to each row passing under the pointer but drops
// or defers the matching `mouseExited` until the mouse physically moves, leaving
// several rows highlighted at once. Rows based on this class re-derive hover from
// the real mouse location on every scroll of the enclosing clip view, so at most
// one row is ever highlighted.

import AppKit

class HoverRowView: NSView {
    private var trackingArea: NSTrackingArea?

    private(set) var isHovered = false {
        didSet { if isHovered != oldValue { hoverStateChanged() } }
    }

    /// Subclass hook: restyle for the new `isHovered` value.
    func hoverStateChanged() {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard window != nil else {
            isHovered = false
            return
        }
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(enclosingScrollDidScroll),
                                               name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func enclosingScrollDidScroll() {
        guard let window else {
            isHovered = false
            return
        }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        isHovered = bounds.contains(p) && visibleRect.contains(p)
    }
}
