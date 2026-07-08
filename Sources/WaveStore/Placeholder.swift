// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveStore — module marker. The real implementation lives in `ObjectStore.swift`
// (PROTOCOL.md §2: oref-keyed object cache, load, subscribe, version-guarded
// merge, apply inline `updates`). `ObjectStore` conforms to
// `WaveCore.ObjectStoreProtocol` and drives loads/subscriptions through any
// `WaveCore.WaveTransport` (implemented by WaveProtocol).

import Foundation
import WaveCore

public enum WaveStoreModule {
    public static let implements = "PROTOCOL.md §2"
}
