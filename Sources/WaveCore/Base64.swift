// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveCore — std base64 helpers.
//
// GUARDS §T (MUST): the Wave wire uses **standard** base64 in BOTH directions —
// `inputdata64` (keystrokes -> ControllerInputCommand) and `data64`
// (blockfile append events / file backfill). It is NOT url-safe
// (`frontend/.../term-model.ts:509-512`). Decoding url-safe input here would
// silently corrupt terminal bytes, so we assert against it in debug builds.

import Foundation

public enum WaveBase64 {
    /// Encode raw bytes to standard base64 (with `+`/`/` and `=` padding).
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
    }

    /// Encode a UTF-8 string's raw bytes to standard base64.
    public static func encode(_ string: String) -> String {
        encode(Data(string.utf8))
    }

    /// Decode standard base64. Returns nil on malformed input.
    ///
    /// GUARDS §T: asserts the input is not url-safe (`-`/`_`), which would
    /// indicate a wrong-encoding bug at the call site rather than valid data.
    public static func decode(_ string: String) -> Data? {
        assert(
            !string.contains("-") && !string.contains("_"),
            "Wave wire base64 is std, not url-safe (GUARDS §T)")
        return Data(base64Encoded: string)
    }
}
