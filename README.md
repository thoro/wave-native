# Wave Native (macOS)

A native macOS frontend for Wave Terminal — **terminal + web blocks + workspaces**
— that reuses the existing Go `wavesrv` backend and renders the UI natively
(AppKit + libghostty) instead of Electron.

**Why:** kill Electron's cold-start latency and ~50 helper processes, and escape
the multi-`WebContentsView` compositing limits (overlapping views, hover/focus/
transparency) that don't exist in native AppKit.

## Design in one paragraph

`wavesrv` is already a separate process that speaks `wshrpc` over WebSocket + an
HTTP service layer; the `wsh` CLI is proof a non-Electron client works. So this
project **rewrites only the frontend in Swift** and talks to an unmodified
`wavesrv`. Terminals are rendered by **libghostty**; web blocks by **WKWebView**;
workspaces/tabs/windows/layout are plain Wave objects driven over the protocol.

## Status

Bootstrapping. Specs + theme are written; Swift implementation happens on macOS.

> ⚠️ **Build environment:** this must be built and run on **macOS with Xcode**
> (AppKit, WKWebView, and libghostty are macOS-only). The specs/scaffold in this
> folder were authored in a Linux container and are **not yet compiled** — treat
> Swift here as a faithful starting scaffold to build on the Mac.

## Layout

```
wave-native/
  docs/
    PROTOCOL.md   # authoritative wavesrv contract (transport, WOS, RPCs, terminal, layout)
    GUARDS.md     # non-negotiable implementation invariants (encode as asserts/tests)
    STYLE.md      # exact visual spec to pixel-match the Electron app (default dark)
    ROADMAP.md    # staged implementation workflow with e2e gates  <-- the build plan
    E2E.md        # Swift end-to-end test harness design (drives a real wavesrv)
  Sources/
    Theme.swift   # the style spec as Swift constants (AppKit)
    ...           # WaveProtocol / WaveStore / WaveTerminal / WaveWeb / WaveLayout / WaveApp
  tests/
    snapshots/    # screenshots diffed against the Electron app
```

## Dependencies (Mac)

- Xcode (Swift 5.9+), macOS 13+.
- **libghostty** — Ghostty's embeddable terminal core (its own macOS app is
  Swift/AppKit, Metal-rendered). Build/link per Ghostty's embedding docs.
- A vendored copy of `wavesrv` (or point at an installed Wave). Plus bundled
  fonts **Inter** + **Hack**.

## First steps

1. Read `docs/PROTOCOL.md` then `docs/GUARDS.md`.
2. Implement `WaveProtocol` (transport) + `WaveStore` (object cache) and get the
   e2e harness in `docs/E2E.md` green against a real `wavesrv` — that proves the
   contract before any UI.
3. Then terminal (libghostty) → layout → web → chrome, per `docs/ROADMAP.md`.
