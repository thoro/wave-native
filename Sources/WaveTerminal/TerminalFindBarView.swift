// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// The per-pane find bar: a compact pill overlaid on the terminal's top-right.
// Search itself runs against the backend's full on-disk scrollback (the view
// owns the RPC + jump logic); this view is just the input + count + nav chrome.
// Field-editor command routing mirrors QuickOpenOverlayView: Enter = next,
// Shift-Enter = previous, Esc = close.

#if canImport(AppKit)
import AppKit

final class TerminalFindBarView: NSView, NSTextFieldDelegate {
    var onQueryChanged: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrev: (() -> Void)?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.96).cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.15).cgColor

        field.placeholderString = "Find in scrollback"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 12)
        field.textColor = .white
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = NSColor(white: 1, alpha: 0.55)
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        configureChevron(prevButton, symbol: "chevron.up", action: #selector(prevPressed))
        configureChevron(nextButton, symbol: "chevron.down", action: #selector(nextPressed))
        configureChevron(closeButton, symbol: "xmark", action: #selector(closePressed))

        for v in [field, countLabel, prevButton, nextButton, closeButton] { addSubview(v) }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 170),

            countLabel.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.widthAnchor.constraint(equalToConstant: 68),

            prevButton.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 6),
            prevButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),
            nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            heightAnchor.constraint(equalToConstant: 30),
        ])
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureChevron(_ button: NSButton, symbol: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.contentTintColor = NSColor(white: 1, alpha: 0.7)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func prevPressed() { onPrev?() }
    @objc private func nextPressed() { onNext?() }
    @objc private func closePressed() { onClose?() }

    var query: String { field.stringValue }

    func setCount(current: Int, total: Int, truncated: Bool) {
        if total == 0 {
            countLabel.stringValue = field.stringValue.isEmpty ? "" : "No results"
        } else {
            countLabel.stringValue = "\(current + 1)/\(total)\(truncated ? "+" : "")"
        }
    }

    func focusField(selectAll: Bool) {
        window?.makeFirstResponder(field)
        if selectAll { field.currentEditor()?.selectAll(nil) }
    }

    /// True when the field editor editing our text field is first responder.
    func ownsFirstResponder(in window: NSWindow?) -> Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate === field
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        onQueryChanged?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onPrev?()
            } else {
                onNext?()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
#endif
