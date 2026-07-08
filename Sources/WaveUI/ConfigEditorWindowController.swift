// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — the raw `settings.json` editor (Electron parity: the config block's JSON
// editor, minus Monaco). A monospaced text view over the whole file; Save validates the
// JSON, refuses to write invalid input, then writes the whole file via the FileService
// RPC (`AppCoordinator.writeConfigFileText`). The backend filewatcher fires the `config`
// event on write, which the coordinator already reloads — so live settings update.
//
// One shared instance (like `SettingsWindowController`) so the gear popover / menu from
// any window targets the same editor, retargeting the presenting window's coordinator.

import AppKit

@MainActor
public final class ConfigEditorWindowController: NSWindowController {
    public static let shared = ConfigEditorWindowController()

    private weak var coordinator: AppCoordinator?

    private var textView: NSTextView!
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Edit Config (settings.json)"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowBackground
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Presentation

    /// Show the editor targeting `coordinator`'s config home, loading the current file.
    public func present(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let window else { return }
        let content = NSView()

        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        guard let tv = scroll.documentView as? NSTextView else { return }
        textView = tv
        tv.isRichText = false
        tv.font = Theme.uiFontMono
        tv.textColor = Theme.textPrimary
        tv.backgroundColor = Theme.blockBg
        tv.insertionPointColor = Theme.textPrimary
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.allowsUndo = true

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = Theme.textSecondary
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail

        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        reloadButton.target = self
        reloadButton.action = #selector(reloadTapped)
        reloadButton.bezelStyle = .rounded
        reloadButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(statusLabel)
        content.addSubview(reloadButton)
        content.addSubview(saveButton)
        window.contentView = content

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -12),

            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: reloadButton.leadingAnchor, constant: -12),

            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            saveButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            reloadButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            reloadButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
        ])
    }

    // MARK: - Load / Save

    @objc private func reloadTapped() { reload() }

    private func reload() {
        guard let coordinator else { return }
        setStatus("Loading…", isError: false)
        Task { @MainActor in
            do {
                let text = try await coordinator.readConfigFileText()
                textView.string = text.isEmpty ? "{\n\n}" : text
                setStatus("Loaded", isError: false)
            } catch {
                setStatus("Failed to load: \(error)", isError: true)
            }
        }
    }

    @objc private func saveTapped() {
        guard let coordinator else { return }
        let text = textView.string
        // JSON-validate BEFORE writing — never persist invalid config.
        if let err = Self.configJSONError(text) {
            setStatus(err, isError: true)
            return
        }
        setStatus("Saving…", isError: false)
        Task { @MainActor in
            do {
                try await coordinator.writeConfigFileText(text)
                setStatus("Saved", isError: false)
            } catch {
                setStatus("Failed to save: \(error)", isError: true)
            }
        }
    }

    private func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? Theme.error : Theme.textSecondary
    }

    // MARK: - Validation (pure, unit-testable)

    /// Validate raw editor text as a settings.json document. Returns an error message to
    /// show (and block the write), or nil when the text is a valid JSON OBJECT — settings
    /// must be a key/value map, never an array/primitive (matches Electron's editor).
    public static func configJSONError(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil } // empty file clears settings (allowed)
        guard let data = trimmed.data(using: .utf8) else { return "Invalid text encoding" }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return "Invalid JSON: \(error.localizedDescription)"
        }
        guard obj is [String: Any] else {
            return "settings.json must be a JSON object (a { key: value } map)"
        }
        return nil
    }
}
