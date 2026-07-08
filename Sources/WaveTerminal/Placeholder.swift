// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveTerminal — implements PROTOCOL.md §4 (ControllerResync, blockfile
// subscribe, HTTP backfill + absolute-byte-offset reconcile, libghostty I/O,
// resize). Encodes GUARDS §T.
//
// NOTE: Foundation placeholder. The WaveTerminal agent owns the real
// implementation. It links libghostty via the `CGhostty` module (see
// Sources/CGhostty/module.modulemap — MARK: MAC-LINK).

import Foundation
import WaveCore
import WaveProtocol
import WaveStore
#if canImport(CGhostty)
import CGhostty
#endif

public enum WaveTerminalModule {
    public static let implements = "PROTOCOL.md §4 / GUARDS §T"
}
