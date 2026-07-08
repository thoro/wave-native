// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveTerminal — incremental scanner that surfaces OSC desktop-notification
// sequences (OSC 9 iTerm2-style, OSC 777 kitty/urxvt-style) from the terminal byte
// stream.
//
// WHY a hand-rolled scanner: the vendored libghostty-vt surfaces a BELL effect
// (GHOSTTY_TERMINAL_OPT_BELL) but exposes NO terminal effect for OSC 9 desktop
// notifications, and its standalone OSC parser only extracts the window-title string
// (GHOSTTY_OSC_DATA_CHANGE_WINDOW_TITLE_STR) — there is no data extractor for a
// notification's title/body. So to recover the message text we run this small
// state machine over the same bytes the sink feeds to libghostty. It is a PURE value
// type (no libghostty, no AppKit) so it is fully unit-testable, and the sink runs it
// OUTSIDE its terminal lock (it never touches the terminal handle).

import Foundation

/// One desktop notification recovered from an OSC sequence.
public struct TerminalNotification: Equatable, Sendable {
    /// OSC 777 carries an explicit title; OSC 9 (iTerm2) does not (nil).
    public let title: String?
    public let body: String
    public init(title: String?, body: String) {
        self.title = title
        self.body = body
    }
}

/// A side effect recovered from an OSC sequence in the terminal byte stream. The scanner
/// frames every `ESC ] … BEL/ST` once and classifies it, so notifications (OSC 9/777) and
/// clipboard writes (OSC 52) come out of a single pass.
public enum OSCEvent: Equatable, Sendable {
    case notification(TerminalNotification)
    /// OSC 52 clipboard WRITE: the decoded bytes to place on the pasteboard (empty = clear).
    case clipboardCopy(Data)
}

/// Incremental OSC notification recognizer. Feed it the same bytes the terminal sees
/// via `scan`; it returns any complete notification sequences found in that chunk.
/// State persists across chunks (a sequence may straddle a `feed` boundary).
///
/// Not thread-safe by itself — the sink only drives it from its serialized `feed`
/// path (one ordered byte stream), so it needs no internal locking.
public struct OSCNotificationScanner {
    /// Cap the buffered OSC payload so a malformed/never-terminated sequence cannot
    /// grow without bound; overflow abandons the in-flight sequence. Sized for OSC 52
    /// clipboard writes, whose base64 payload routinely exceeds a few KB (a smaller cap
    /// would truncate legitimate copies) while still bounding a runaway sequence.
    private static let maxPayload = 1 << 20  // 1 MiB

    private enum State {
        case idle          // outside any escape
        case gotESC        // saw 0x1b
        case inOSC         // inside `ESC ]` ... collecting the payload
        case inOSCgotESC   // inside OSC, saw 0x1b (possible ST = `ESC \`)
    }

    private var state: State = .idle
    private var payload: [UInt8] = []

    public init() {}

    /// Process `bytes`, returning every complete OSC event that finished within (or
    /// straddling into) this chunk.
    public mutating func scan(_ bytes: Data) -> [OSCEvent] {
        var out: [OSCEvent] = []
        for byte in bytes {
            switch state {
            case .idle:
                if byte == 0x1b { state = .gotESC }
            case .gotESC:
                if byte == 0x5d {            // ']' → OSC introducer
                    state = .inOSC
                    payload.removeAll(keepingCapacity: true)
                } else if byte == 0x1b {     // another ESC: stay armed
                    state = .gotESC
                } else {
                    state = .idle
                }
            case .inOSC:
                if byte == 0x07 || byte == 0x9c {           // BEL or single-byte ST
                    if let n = Self.parse(payload) { out.append(n) }
                    state = .idle
                } else if byte == 0x1b {
                    state = .inOSCgotESC
                } else {
                    payload.append(byte)
                    if payload.count > Self.maxPayload { state = .idle }
                }
            case .inOSCgotESC:
                if byte == 0x5c {                            // '\' → ST terminator
                    if let n = Self.parse(payload) { out.append(n) }
                    state = .idle
                } else if byte == 0x1b {                     // ESC ESC: re-arm inside OSC
                    state = .inOSCgotESC
                } else {
                    // Abnormal byte after ESC inside an OSC: abandon the sequence and
                    // re-interpret this byte from idle (it may begin a fresh escape).
                    state = .idle
                    if byte == 0x1b { state = .gotESC }
                }
            }
        }
        return out
    }

    /// Parse a completed OSC payload (the bytes between `ESC ]` and the terminator)
    /// into an event, or nil when it is not a command we surface.
    static func parse(_ payload: [UInt8]) -> OSCEvent? {
        let text = String(decoding: payload, as: UTF8.self)
        guard let sep = text.firstIndex(of: ";") else { return nil }
        let code = String(text[text.startIndex..<sep])
        let rest = String(text[text.index(after: sep)...])

        switch code {
        case "9":
            // OSC 9 is overloaded: iTerm2 desktop notifications (`9 ; <message>`) share
            // the number with ConEmu progress/commands (`9 ; <digit> ; …`) and ghostty's
            // OSC 9 pwd. Skip the ConEmu/numeric forms so only a plain message notifies.
            guard !rest.isEmpty, !Self.looksLikeConEmu(rest) else { return nil }
            return .notification(TerminalNotification(title: nil, body: rest))
        case "777":
            // urxvt/kitty: `777 ; notify ; <title> ; <body>` (body may itself contain ';').
            let parts = rest.components(separatedBy: ";")
            guard parts.first == "notify" else { return nil }
            let args = Array(parts.dropFirst())
            guard !args.isEmpty else { return nil }
            if args.count == 1 {
                guard !args[0].isEmpty else { return nil }
                return .notification(TerminalNotification(title: nil, body: args[0]))
            }
            let title = args[0].isEmpty ? nil : args[0]
            let body = args[1...].joined(separator: ";")
            guard !body.isEmpty else { return nil }
            return .notification(TerminalNotification(title: title, body: body))
        case "52":
            return Self.parseClipboard(rest)
        default:
            return nil
        }
    }

    /// Parse the payload of an OSC 52 sequence (`52 ; <Pc> ; <Pd>`, `rest` = `<Pc> ; <Pd>`).
    /// We implement clipboard WRITE only: `Pd` is the base64 clipboard contents. A read
    /// query (`Pd == "?"`) is dropped — honoring it would let a program running in the
    /// terminal exfiltrate the host clipboard. The `Pc` target (c/p/s/q/0-7) is accepted
    /// but not differentiated: macOS has a single general pasteboard.
    private static func parseClipboard(_ rest: String) -> OSCEvent? {
        guard let sep = rest.firstIndex(of: ";") else { return nil }
        let pd = String(rest[rest.index(after: sep)...])
        if pd == "?" { return nil }  // read request — not supported
        guard let data = Data(base64Encoded: pd, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return .clipboardCopy(data)
    }

    /// A ConEmu OSC 9 form: the message starts with a numeric subcommand followed by
    /// `;` (e.g. `4;50` progress) or is a bare number. iTerm2 notification text is
    /// free-form prose, so this conservatively filters out the control variants.
    private static func looksLikeConEmu(_ rest: String) -> Bool {
        guard let first = rest.first, first.isNumber else { return false }
        if rest.count == 1 { return true }
        let second = rest[rest.index(after: rest.startIndex)]
        return second == ";"
    }
}
