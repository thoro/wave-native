// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — a reusable keyboard-driven quick-open overlay. One component backs both
// the Cmd-Shift-O workspace switcher and the Cmd-K tab switcher (Electron parity):
// a dimmed backdrop, a centered rounded panel with a search field and a filtered,
// keyboard-navigable list. Type to filter, Up/Down to move, Enter to pick, Esc or
// click-outside to dismiss.

import AppKit

/// One selectable entry. `icon`/`color` are optional Wave icon hints (used by the
/// workspace switcher); the tab switcher leaves them nil.
struct QuickOpenItem: Equatable {
    let id: String
    let title: String
    let icon: String?
    let color: String?

    init(id: String, title: String, icon: String? = nil, color: String? = nil) {
        self.id = id
        self.title = title
        self.icon = icon
        self.color = color
    }
}

/// The overlay view. Add it to a host view (filling its bounds) and call
/// `focusSearch()` once it is in the window so the search field takes
/// firstResponder. Selection / dismissal are reported via the callbacks.
final class QuickOpenOverlayView: NSView, NSTextFieldDelegate {
    var onSelect: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    // Panel metrics mirror the Electron quick-switch modal (radius 8, dark, shadowed).
    private let panelWidth: CGFloat = 360
    private let rowHeight: CGFloat = 30
    private let maxVisibleRows = 10

    private let panel = NonDragView()
    private let searchField = NSTextField()
    private let scrollView = NSScrollView()
    private let listStack = NSStackView()
    private var listHeightConstraint: NSLayoutConstraint!

    private var allItems: [QuickOpenItem] = []
    private var filtered: [QuickOpenItem] = []
    private var selectedIndex = 0
    private var rows: [QuickOpenRowView] = []
    private let allowFreeEntry: Bool

    /// Id prefix marking the synthetic free-entry row (connection typeahead). The
    /// presenter strips it to recover the raw typed value.
    static let freeEntryPrefix = "__free__:"

    init(placeholder: String, items: [QuickOpenItem], initialSelectionId: String?,
         allowFreeEntry: Bool = false) {
        self.allItems = items
        self.allowFreeEntry = allowFreeEntry
        super.init(frame: .zero)
        wantsLayer = true
        // Dim the chrome behind the panel without fully hiding it (STYLE modal scrim).
        layer?.backgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35).cgColor
        buildPanel(placeholder: placeholder)
        filtered = items
        // Pre-select the current workspace/tab so Enter without typing is a no-op-ish
        // confirm of the active item (matches Electron opening on the active entry).
        if let initialSelectionId, let idx = items.firstIndex(where: { $0.id == initialSelectionId }) {
            selectedIndex = idx
        }
        rebuildRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Build

    private func buildPanel(placeholder: String) {
        panel.wantsLayer = true
        panel.layer?.backgroundColor = Theme.modalBackground.cgColor
        panel.layer?.cornerRadius = Theme.radiusLarge
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = Theme.border.cgColor
        panel.shadow = NSShadow()
        panel.layer?.shadowColor = Theme.modalShadowColor.cgColor
        panel.layer?.shadowRadius = Theme.modalShadowRadius
        panel.layer?.shadowOpacity = 1
        panel.layer?.shadowOffset = Theme.modalShadowOffset
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        searchField.placeholderString = placeholder
        searchField.font = Theme.uiFont
        searchField.textColor = Theme.textPrimary
        searchField.drawsBackground = false
        searchField.isBordered = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(searchField)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.border.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(divider)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack)
        scrollView.documentView = doc
        panel.addSubview(scrollView)

        listHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: rowHeight)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 120),
            panel.widthAnchor.constraint(equalToConstant: panelWidth),

            searchField.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),

            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            divider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6),
            listHeightConstraint,

            doc.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            listStack.topAnchor.constraint(equalTo: doc.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
    }

    /// Move firstResponder onto the search field. Call after the overlay is in a window.
    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    // MARK: - Rows

    private func rebuildRows() {
        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        if selectedIndex >= filtered.count { selectedIndex = max(0, filtered.count - 1) }
        for (idx, item) in filtered.enumerated() {
            let row = QuickOpenRowView(item: item, height: rowHeight) { [weak self] in
                self?.confirm(index: idx)
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            rows.append(row)
        }
        let visible = min(max(filtered.count, 1), maxVisibleRows)
        listHeightConstraint.constant = CGFloat(visible) * rowHeight
        refreshHighlight()
    }

    private func refreshHighlight() {
        for (idx, row) in rows.enumerated() { row.isSelected = (idx == selectedIndex) }
        scrollSelectionVisible()
    }

    private func scrollSelectionVisible() {
        guard selectedIndex < rows.count else { return }
        rows[selectedIndex].scrollToVisible(rows[selectedIndex].bounds)
    }

    private func applyFilter(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let q = trimmed.lowercased()
        let previousId = (selectedIndex < filtered.count) ? filtered[selectedIndex].id : nil
        filtered = q.isEmpty ? allItems : allItems.filter { $0.title.lowercased().contains(q) }
        // Connection typeahead: offer the typed text as a NEW connection when it does
        // not already name one of the rows (Electron's free-entry "user@host" row).
        if allowFreeEntry, !trimmed.isEmpty,
           !allItems.contains(where: { $0.title.lowercased() == q }) {
            filtered.append(QuickOpenItem(id: Self.freeEntryPrefix + trimmed, title: "Connect to \"\(trimmed)\""))
        }
        // Keep the highlight on the same row if it survives the filter, else reset.
        if let previousId, let idx = filtered.firstIndex(where: { $0.id == previousId }) {
            selectedIndex = idx
        } else {
            selectedIndex = 0
        }
        rebuildRows()
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + filtered.count) % filtered.count
        refreshHighlight()
    }

    private func confirm(index: Int) {
        guard index >= 0, index < filtered.count else { return }
        onSelect?(filtered[index].id)
    }

    // MARK: - Mouse / keyboard dismissal

    override func mouseDown(with event: NSEvent) {
        // Click outside the panel dismisses (click-through inside the panel is handled
        // by the panel's own subviews / rows).
        let p = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(p) { onDismiss?() }
    }

    // NSTextField forwards Up/Down/Enter/Esc as command selectors while editing.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1); return true
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.insertNewline(_:)): confirm(index: selectedIndex); return true
        case #selector(NSResponder.cancelOperation(_:)): onDismiss?(); return true
        default: return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }
}

/// A single quick-open row: optional tinted icon + title, hover/selection highlight.
final class QuickOpenRowView: HoverRowView {
    var isSelected = false { didSet { refresh() } }

    private let action: () -> Void
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(item: QuickOpenItem, height: CGFloat, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.radiusSmall

        let hasIcon = item.icon != nil
        if hasIcon {
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.image = WorkspaceSwitcherView.iconImage(forWaveIcon: item.icon)
            iconView.contentTintColor = (item.color.flatMap(WorkspaceSwitcherView.color(from:))) ?? Theme.accent
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)
        }

        label.font = Theme.uiFont
        label.textColor = Theme.textSecondary
        label.lineBreakMode = .byTruncatingTail
        label.stringValue = item.title
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let labelLeading = hasIcon
            ? label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Theme.actionGap)
            : label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            labelLeading,
        ])
        if hasIcon {
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 15),
                iconView.heightAnchor.constraint(equalToConstant: 15),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func hoverStateChanged() { refresh() }

    private func refresh() {
        let bg: NSColor = isSelected ? Theme.highlightBackground : (isHovered ? Theme.hoverBackground : .clear)
        layer?.backgroundColor = bg.cgColor
        label.textColor = (isSelected || isHovered) ? Theme.textPrimary : Theme.textSecondary
    }

    override func mouseDown(with event: NSEvent) { action() }
}
