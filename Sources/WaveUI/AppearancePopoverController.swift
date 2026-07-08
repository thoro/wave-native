// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — the PER-WINDOW appearance popover, anchored to the tab-bar gear button.
//
// Window appearance (opacity / transparency / blur) is inherently per-window, so it
// belongs on the window's own chrome rather than in the single shared Settings window.
// This controller hosts the live controls; each change is applied immediately to THIS
// window via the `onChange` callbacks (the owning `WaveWindowController` mutates its
// NSWindow). It also offers escape hatches to the raw `settings.json` editor and the
// full Settings window.

import AppKit

/// Hosts the per-window appearance controls shown inside the gear `NSPopover`.
@MainActor
final class AppearancePopoverController: NSViewController {
    /// Live callbacks into the owning window controller (applied to THIS window only).
    var onOpacityChange: ((Double) -> Void)?
    var onTransparentChange: ((Bool) -> Void)?
    var onBlurChange: ((Bool) -> Void)?
    /// Push THIS window's current appearance to every open window (and persist it).
    var onApplyToAll: (() -> Void)?
    var onEditConfig: (() -> Void)?
    var onMoreSettings: (() -> Void)?

    private var appearance: WindowAppearance

    private let opacitySlider = NSSlider()
    private let transparentSwitch = NSSwitch()
    private let blurSwitch = NSSwitch()

    /// One fixed control-column width shared by every appearance row, so Opacity /
    /// Transparent / Blur align down a single edge regardless of each control's intrinsic
    /// width (the slider is wide, the switches are narrow).
    private static let controlWidth: CGFloat = 150

    init(appearance: WindowAppearance) {
        self.appearance = appearance
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Re-seed the controls from the window's current appearance (on each present, in
    /// case it changed since the popover was last shown).
    func update(appearance: WindowAppearance) {
        self.appearance = appearance
        opacitySlider.doubleValue = appearance.opacity
        transparentSwitch.state = appearance.transparent ? .on : .off
        blurSwitch.state = appearance.blur ? .on : .off
    }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: "Window Appearance")
        header.font = Theme.headerFont
        header.textColor = Theme.textPrimary
        stack.addArrangedSubview(header)

        opacitySlider.minValue = WindowAppearance.minOpacity
        opacitySlider.maxValue = 1.0
        opacitySlider.doubleValue = appearance.opacity
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged)
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false
        opacitySlider.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true

        transparentSwitch.state = appearance.transparent ? .on : .off
        transparentSwitch.target = self
        transparentSwitch.action = #selector(transparentChanged)

        blurSwitch.state = appearance.blur ? .on : .off
        blurSwitch.target = self
        blurSwitch.action = #selector(blurChanged)

        // Lay the three rows out in a grid (trailing label | leading control, one fixed
        // control width, every row vertically centered) — the same approach that aligns
        // the Settings form. A stack centered each label on the control's intrinsic box,
        // so the tall slider left "Opacity" floating above its track; the grid pins all
        // three labels to one x and centers each control in its row.
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 12
        grid.rowSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 1).width = Self.controlWidth
        addAppearanceRow(grid, "Opacity", control: opacitySlider)
        addAppearanceRow(grid, "Transparent", control: transparentSwitch)
        addAppearanceRow(grid, "Blur", control: blurSwitch)
        stack.addArrangedSubview(grid)

        let applyAll = NSButton(title: "Apply to All Windows", target: self, action: #selector(applyToAllTapped))
        applyAll.bezelStyle = .rounded
        applyAll.controlSize = .regular
        applyAll.font = Theme.uiFont
        applyAll.translatesAutoresizingMaskIntoConstraints = false
        applyAll.widthAnchor.constraint(equalToConstant: 240).isActive = true
        stack.addArrangedSubview(applyAll)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 240).isActive = true
        stack.addArrangedSubview(separator)

        let editConfig = linkButton("Edit config…", action: #selector(editConfigTapped))
        stack.addArrangedSubview(editConfig)
        let moreSettings = linkButton("More settings…", action: #selector(moreSettingsTapped))
        stack.addArrangedSubview(moreSettings)

        let container = NSView()
        container.addSubview(stack)
        // Margins as explicit container-edge constants: NSStackView.edgeInsets
        // proved unreliable under NSPopover's fitting-size pass (the fields sat
        // flush against the popover chrome).
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        view = container
    }

    /// Append a [trailing label | leading control] row to the appearance grid, vertically
    /// centered. The grid's shared control-column width is what makes Opacity/Transparent/
    /// Blur align uniformly regardless of each control's intrinsic height.
    private func addAppearanceRow(_ grid: NSGridView, _ title: String, control: NSView) {
        let label = NSTextField(labelWithString: title)
        label.font = Theme.uiFont
        label.textColor = Theme.textSecondary
        control.translatesAutoresizingMaskIntoConstraints = false
        let row = grid.addRow(with: [label, control])
        row.yPlacement = .center
    }

    private func linkButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = Theme.accent
        button.font = Theme.uiFont
        button.alignment = .left
        return button
    }

    @objc private func opacityChanged() {
        appearance.opacity = opacitySlider.doubleValue
        onOpacityChange?(opacitySlider.doubleValue)
    }

    @objc private func transparentChanged() {
        let on = transparentSwitch.state == .on
        appearance.transparent = on
        onTransparentChange?(on)
    }

    @objc private func blurChanged() {
        let on = blurSwitch.state == .on
        appearance.blur = on
        onBlurChange?(on)
    }

    @objc private func applyToAllTapped() { onApplyToAll?() }
    @objc private func editConfigTapped() { onEditConfig?() }
    @objc private func moreSettingsTapped() { onMoreSettings?() }
}
