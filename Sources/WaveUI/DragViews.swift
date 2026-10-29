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
// window. So NO view opts into `mouseDownCanMoveWindow`; instead every chrome surface
// (the strip itself, the widget bar, the `DragView` fillers) starts the window drag
// EXPLICITLY from `mouseDown` via `handleChromeMouseDown`. Because that only runs for
// a press no interactive child consumed (pills, buttons and the switcher all swallow
// their mouseDown), the whole strip — under the traffic lights, the gaps between
// pills, the margin around the gear — moves the window without ever pre-empting a
// pill drag.

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

/// Marker for a chrome view whose unhandled press moves the window (see
/// `handleChromeMouseDown`). Lets layout tests assert that a point on the chrome
/// resolves to a drag surface and not to an interactive child.
protocol WindowDragSurface: NSView {}

/// Shared `mouseDown` for every `WindowDragSurface`. The window has NO native drag
/// region (`WaveWindow.isMovable == false` — the server-side title-bar region captured
/// pill drags before the app saw them), so the drag is started EXPLICITLY here:
/// `performDrag(with:)` hands the gesture to the system (native movement incl. edge
/// snapping) and works while `isMovable` is false. A double-click is the title-bar
/// action (zoom/minimize per the user's system setting) instead of a drag.
func handleChromeMouseDown(_ event: NSEvent, in view: NSView) {
    guard let window = view.window else { return }
    if event.clickCount == 2 {
        (window as? WaveWindow)?.performTitleBarDoubleClickAction()
        return
    }
    window.performDrag(with: event)
}

/// A container that IS draggable (filler regions of the strip). Redundant with the
/// strip's own `mouseDown` for dragging, but it stays as the required-width cap in the
/// strip's constraint chain (see `TabBarView.setup`).
final class DragView: NSView, WindowDragSurface {
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        handleChromeMouseDown(event, in: self)
    }
}

/// Env-gated drag-and-drop tracing (WAVE_DNDDEBUG=1): logs the tab/pane drag gesture
/// path (source begin/end, destination enter/drop, RPC dispatch) for live diagnosis.
func dndLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["WAVE_DNDDEBUG"] != nil else { return }
    NSLog("DNDDBG %@", message())
}
