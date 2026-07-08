// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// E2E-7 (visual) — offscreen rendering + snapshot diffing support.
//
// Two complementary checks (docs/E2E.md "Snapshot tests", STYLE.md "Acceptance"):
//   1. Deterministic pixel sampling of the rendered chrome against the literal
//      Theme.swift / STYLE.md values (window #222, tab active fill = white@10% over
//      #222, 2px accent #58c142 focus border, terminal #000). Font-independent, so
//      it is stable even where Inter/Hack are not installed.
//   2. PNG baseline diffing of whole components vs the Electron app's default-dark
//      screenshots in `tests/snapshots/`. See tests/snapshots/README.md for how to
//      capture those baselines. Run with WAVE_NATIVE_RECORD_SNAPSHOTS=1 to (re)write
//      the native baselines.
//
// Rendering uses AppKit's documented offscreen path
// (`bitmapImageRepForCachingDisplay` + `cacheDisplay`), the same approach
// swift-snapshot-testing uses for NSView. Requires a macOS GUI runner; set
// WAVE_NATIVE_SKIP_GUI=1 to skip the visual gate on a headless box.

import AppKit
import XCTest

enum SnapshotTester {
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["WAVE_NATIVE_RECORD_SNAPSHOTS"] == "1"
    }
    static var guiSkipped: Bool {
        ProcessInfo.processInfo.environment["WAVE_NATIVE_SKIP_GUI"] == "1"
    }

    /// `<package>/tests/snapshots`, derived from this source file's location.
    /// File path: .../wave-native/Tests/WaveE2ETests/SnapshotSupport.swift
    static func snapshotsDir(file: StaticString = #filePath) -> URL {
        let f = URL(fileURLWithPath: "\(file)")
        let packageRoot = f
            .deletingLastPathComponent()  // WaveE2ETests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // wave-native
        return packageRoot.appendingPathComponent("tests/snapshots", isDirectory: true)
    }

    static func baselineExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: snapshotsDir().appendingPathComponent("\(name).png").path)
    }

    static func skipIfNoGUI(file: StaticString = #filePath, line: UInt = #line) throws {
        if guiSkipped {
            throw XCTSkip("WAVE_NATIVE_SKIP_GUI=1: visual gate skipped (no GUI runner).",
                          file: file, line: line)
        }
        // Touch the shared app so AppKit drawing has a context.
        _ = NSApplication.shared
    }

    // MARK: - Offscreen render

    /// Render `view` composited over an opaque `background` and return the bitmap.
    /// The opaque backing makes alpha colors (e.g. white@10% pills) deterministic.
    static func renderComposited(
        _ view: NSView, size: CGSize, background: NSColor
    ) -> NSBitmapImageRep? {
        let container = CompositingContainer(background: background)
        container.frame = CGRect(origin: .zero, size: size)
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)

        // Host in a borderless window so layer-backed content has a real context.
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        // Pin the backing to sRGB: cacheDisplay captures through the window's color
        // space, which defaults to the DISPLAY profile — on P3/calibrated screens
        // every sampled value drifts off the sRGB theme constants (#222 reads #2D)
        // and the assertions become machine-dependent.
        window.colorSpace = .sRGB
        window.contentView = container
        container.layoutSubtreeIfNeeded()

        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
            return nil
        }
        container.cacheDisplay(in: container.bounds, to: rep)
        return rep
    }

    // MARK: - Pixel sampling

    /// `colorAt` hands back the RAW pixel components but in a device colorspace,
    /// ignoring the rep's tag — running `usingColorSpace(.sRGB)` on that applies a
    /// second (display-profile) transform and #222222 pixels read as #2D2D2D. The
    /// render path pins the rep to sRGB, so RE-TAG the raw components instead.
    private static func srgbTagged(_ c: NSColor?) -> NSColor? {
        guard let c else { return nil }
        return NSColor(srgbRed: c.redComponent, green: c.greenComponent,
                       blue: c.blueComponent, alpha: c.alphaComponent)
    }

    /// sRGB color at a fractional position (0..1, origin top-left of the bitmap).
    static func color(_ rep: NSBitmapImageRep, atFraction fx: CGFloat, _ fy: CGFloat) -> NSColor? {
        let x = min(max(Int(CGFloat(rep.pixelsWide) * fx), 0), rep.pixelsWide - 1)
        let y = min(max(Int(CGFloat(rep.pixelsHigh) * fy), 0), rep.pixelsHigh - 1)
        return srgbTagged(rep.colorAt(x: x, y: y))
    }

    /// sRGB color at a point in *view points* (origin top-left), scale-corrected
    /// for retina backing.
    static func color(_ rep: NSBitmapImageRep, atPoint pt: CGPoint, viewSize: CGSize) -> NSColor? {
        let sx = CGFloat(rep.pixelsWide) / max(viewSize.width, 1)
        let sy = CGFloat(rep.pixelsHigh) / max(viewSize.height, 1)
        let x = min(max(Int(pt.x * sx), 0), rep.pixelsWide - 1)
        let y = min(max(Int(pt.y * sy), 0), rep.pixelsHigh - 1)
        return srgbTagged(rep.colorAt(x: x, y: y))
    }

    static func assertColor(
        _ actual: NSColor?, _ expected: NSColor, tolerance: CGFloat = 3.0 / 255.0,
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let actual = actual?.usingColorSpace(.sRGB),
              let want = expected.usingColorSpace(.sRGB) else {
            XCTFail("\(message): could not resolve sRGB color", file: file, line: line); return
        }
        let dr = abs(actual.redComponent - want.redComponent)
        let dg = abs(actual.greenComponent - want.greenComponent)
        let db = abs(actual.blueComponent - want.blueComponent)
        XCTAssertLessThanOrEqual(
            max(dr, dg, db), tolerance,
            "\(message): expected ~\(hex(want)) got \(hex(actual))",
            file: file, line: line)
    }

    private static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02X%02X%02X",
                      Int((s.redComponent * 255).rounded()),
                      Int((s.greenComponent * 255).rounded()),
                      Int((s.blueComponent * 255).rounded()))
    }

    /// Composite `over` (alpha) atop opaque `base` in sRGB — for predicting the
    /// rendered result of a translucent fill (e.g. white@10% pill over #222).
    static func composite(_ over: NSColor, on base: NSColor) -> NSColor {
        let o = over.usingColorSpace(.sRGB)!
        let b = base.usingColorSpace(.sRGB)!
        let a = o.alphaComponent
        func mix(_ f: CGFloat, _ g: CGFloat) -> CGFloat { f * a + g * (1 - a) }
        return NSColor(srgbRed: mix(o.redComponent, b.redComponent),
                       green: mix(o.greenComponent, b.greenComponent),
                       blue: mix(o.blueComponent, b.blueComponent), alpha: 1)
    }

    // MARK: - PNG baseline diff (vs Electron / recorded native baseline)

    /// Compare `rep` to `tests/snapshots/<name>.png`. Writes the baseline (and
    /// fails with a "recorded" note) when missing or in record mode; on mismatch
    /// writes `<name>.failure.png` next to the baseline for inspection.
    static func assertBaseline(
        _ rep: NSBitmapImageRep, named name: String, tolerance: Double = 0.02,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let dir = snapshotsDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        guard let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("could not PNG-encode snapshot \(name)", file: file, line: line); return
        }

        let exists = FileManager.default.fileExists(atPath: url.path)
        if isRecording || !exists {
            try? png.write(to: url)
            XCTFail("recorded baseline \(name).png (no diff performed). " +
                    "Re-run without WAVE_NATIVE_RECORD_SNAPSHOTS to compare.",
                    file: file, line: line)
            return
        }

        guard let baseData = try? Data(contentsOf: url),
              let baseRep = NSBitmapImageRep(data: baseData) else {
            XCTFail("could not read baseline \(name).png", file: file, line: line); return
        }
        let diff = averageChannelDiff(rep, baseRep)
        if diff > tolerance {
            let failURL = dir.appendingPathComponent("\(name).failure.png")
            try? png.write(to: failURL)
            XCTFail(String(format: "snapshot %@ differs by %.4f (> %.4f); wrote %@.failure.png",
                           name, diff, tolerance, name), file: file, line: line)
        }
    }

    /// Mean per-pixel max-channel difference in 0..1. Returns 1.0 (max) on a size
    /// mismatch so a re-layout/scale change fails loudly.
    static func averageChannelDiff(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
              a.pixelsWide > 0, a.pixelsHigh > 0 else { return 1.0 }
        var total = 0.0
        var count = 0
        // Sample a grid (full-res scans are slow + flaky on sub-pixel AA).
        let stepsX = min(a.pixelsWide, 64)
        let stepsY = min(a.pixelsHigh, 64)
        for iy in 0..<stepsY {
            let y = iy * a.pixelsHigh / stepsY
            for ix in 0..<stepsX {
                let x = ix * a.pixelsWide / stepsX
                guard let ca = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let cb = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let d = max(abs(ca.redComponent - cb.redComponent),
                            abs(ca.greenComponent - cb.greenComponent),
                            abs(ca.blueComponent - cb.blueComponent))
                total += Double(d); count += 1
            }
        }
        return count == 0 ? 1.0 : total / Double(count)
    }
}

/// Flipped, opaque, layer-backed host so offscreen renders are deterministic and
/// share the chrome's top-left coordinate convention (RootContentView is flipped).
private final class CompositingContainer: NSView {
    init(background: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = background.cgColor
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
}
