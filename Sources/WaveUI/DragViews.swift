// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — window-drag helpers. STYLE.md §4/§6: the empty parts of the 33px tab
// strip are a window-drag region; interactive children (tabs, buttons) are not.
// We use a frameless full-size-content window, so AppKit's `mouseDownCanMoveWindow`
// per-view opt-in is how we get a native title-bar drag. It coexists with the tab
// pills' own NSDraggingSession and gives title-bar behaviors (double-click to zoom,
// edge tiling) for free — unlike a manual `performDrag(with:)`, which runs a MODAL
// loop that fights the pill drag so a tab drag can never complete.
//
// IMPORTANT — why the backdrop is NOT draggable: AppKit's window drag region is the
// UNION of every `mouseDownCanMoveWindow==true` view's frame. A non-draggable view
// only carves a hole out of that region when it is a DESCENDANT of the draggable
// view — a non-draggable SIBLING painted on top does NOT. The pills live in a
// sibling container, not inside the backdrop, so a full-strip draggable backdrop
// made the whole strip (including the area behind every pill) a window-drag region.
// A click still reached the pill (a press with no movement never starts a window
// drag), but the moment the pointer moved past AppKit's drag slop the native window
// move pre-empted the pill's NSDraggingSession — i.e. dragging a tab moved the
// window. So the backdrop is non-draggable and window dragging is provided only by
// explicit `DragView` fillers laid out over the genuinely-empty strip regions, where
// nothing draggable ever sits behind a pill.

import AppKit

/// A blurred translucent background. NOT draggable — see the file header for why a
/// full-strip draggable backdrop hijacked tab drags.
final class TabStripBackgroundView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// A plain container that is NOT draggable (wraps interactive chrome).
final class NonDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// A container that IS draggable (filler regions of the strip). The window has NO
/// native drag region (`WaveWindow.isMovable == false` — the server-side title-bar
/// region captured pill drags before the app saw them), so this view starts the
/// window drag EXPLICITLY. `performDrag(with:)` hands the gesture to the system
/// (native movement incl. edge snapping), and works while `isMovable` is false.
final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Env-gated drag-and-drop tracing (WAVE_DNDDEBUG=1): logs the tab/pane drag gesture
/// path (source begin/end, destination enter/drop, RPC dispatch) for live diagnosis.
func dndLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["WAVE_DNDDEBUG"] != nil else { return }
    NSLog("DNDDBG %@", message())
}
