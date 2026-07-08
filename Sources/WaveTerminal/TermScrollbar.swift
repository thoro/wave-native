// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Line-space scrollbar math for the virtualized terminal. The scroll domain is
// LOGICAL LINES [0, totalLines] of the on-disk term file (history + live):
// search hits arrive as exact line numbers from the backend, so hit markers
// are exact by construction regardless of which chunks are parsed; only the
// thumb (an affordance) uses the rows-per-line estimate. Pure and
// unit-testable; drawing/interaction live in GhosttyTerminalView.

import Foundation

public struct TermScrollbarGeometry: Equatable {
    public var thumbY: CGFloat
    public var thumbHeight: CGFloat
    /// Deduped marker pixel rows (virtualized: O(track pixels), never O(hits)).
    public var markerYs: [CGFloat]
}

public enum TermScrollbarMath {
    public static let minThumb: CGFloat = 24

    public static func fraction(ofLine line: Double, totalLines: Double) -> CGFloat {
        guard totalLines > 0 else { return 0 }
        return CGFloat(Swift.max(0, Swift.min(1, line / totalLines)))
    }

    /// Geometry for the track. Returns nil when there is nothing to show
    /// (content fits the screen and no markers).
    public static func geometry(
        topLine: Double,
        linesOnScreen: Double,
        totalLines: Double,
        matchLines: [Int64],
        trackHeight: CGFloat
    ) -> TermScrollbarGeometry? {
        guard trackHeight > 0, totalLines > 0 else { return nil }
        let needsThumb = totalLines > linesOnScreen
        guard needsThumb || !matchLines.isEmpty else { return nil }
        let visibleFrac = Swift.max(0.01, Swift.min(1, linesOnScreen / totalLines))
        let thumbHeight = Swift.max(minThumb, trackHeight * CGFloat(visibleFrac))
        let scrollableLines = Swift.max(1, totalLines - linesOnScreen)
        let posFrac = Swift.max(0, Swift.min(1, topLine / scrollableLines))
        let thumbY = CGFloat(posFrac) * (trackHeight - thumbHeight)
        var pixelRows = Set<CGFloat>()
        for line in matchLines {
            let y = (fraction(ofLine: Double(line), totalLines: totalLines) * (trackHeight - 1)).rounded()
            pixelRows.insert(y)
        }
        return TermScrollbarGeometry(
            thumbY: thumbY,
            thumbHeight: thumbHeight,
            markerYs: pixelRows.sorted())
    }

    /// Map a click y on the track back to a logical line.
    public static func line(atTrackY y: CGFloat, trackHeight: CGFloat, totalLines: Double) -> Int64 {
        guard trackHeight > 0 else { return 0 }
        let frac = Double(Swift.max(0, Swift.min(1, y / trackHeight)))
        return Int64((frac * totalLines).rounded())
    }
}
