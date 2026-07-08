// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — AppKit views/view-models for window/tabs/workspaces, block chrome,
// terminal/web hosting, and layout rendering. Owns the visual spec (Theme.swift,
// STYLE.md) and the init sequence (PROTOCOL.md §7). Depends on every feature
// module + WaveCore.
//
// NOTE: Foundation/UI placeholder. The WaveUI agent owns the real
// implementation. `Theme.swift` (the pixel-matched visual constants) lives in
// this target.

import Foundation
import WaveCore
import WaveProtocol
import WaveStore
import WaveCommands
import WaveTerminal
import WaveLayout
import WaveWeb

public enum WaveUIModule {
    public static let implements = "PROTOCOL.md §7 / STYLE.md"
}
