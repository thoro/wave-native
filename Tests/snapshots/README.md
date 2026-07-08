# Snapshot baselines (E2E-7 visual gate)

This directory holds the PNG baselines that `SnapshotTests.swift` diffs the native
chrome against. The goal (STYLE.md "Acceptance"): the native window looks
**identical** to Wave's Electron app in its default **dark** theme.

There are two kinds of baseline here:

| Baseline name        | What it is                                  | Source            |
|----------------------|---------------------------------------------|-------------------|
| `*-default.png`, `*-focused.png`, `*-active.png` | The **native** render, recorded by the test bundle | `WAVE_NATIVE_RECORD_SNAPSHOTS=1` |
| `electron-*.png`     | The **Electron** reference screenshots      | captured by hand (below) |

The deterministic pixel-sampling assertions in `SnapshotTests.swift` need **no**
baseline (they check literal Theme/STYLE values). The `assertBaseline(...)` diffs
are the pixel-for-pixel regression net and need the files below.

## Recording the native baselines

Run the visual gate in record mode on a macOS GUI runner with Inter + Hack
installed (so fonts match the Electron app):

```sh
WAVE_NATIVE_RECORD_SNAPSHOTS=1 \
  xcodebuild test -scheme WaveNative -only-testing:WaveE2ETests/SnapshotTests
```

This writes `window-default.png`, `pill-active.png`, `block-focused.png`,
`tabbar-default.png`. Commit them. Re-run **without** the env var to compare.
On a mismatch the test writes `<name>.failure.png` beside the baseline.

> Fonts matter: `Theme.swift` falls back to system fonts when Inter/Hack are
> absent, which changes glyph rasterization. Record on the same font setup you
> compare against, and keep the baselines machine-consistent (ideally one CI lane).

## Capturing the Electron baselines (the "looks identical" reference)

These are captured once from the real Wave Electron app, default dark theme, at
zoom 1.0 (so 1 CSS px == 1 pt), on a Retina display.

1. Launch the Electron app from a clean profile so the default-dark theme and the
   stock starter workspace are in effect:

   ```sh
   WAVETERM_DATA_HOME=$(mktemp -d) WAVETERM_CONFIG_HOME=$(mktemp -d) \
     task electron:dev      # or run the packaged app
   ```

2. Make sure UI zoom is 1.0 (View → Actual Size / Cmd-0) so pixel dimensions line
   up with the native `Theme` point sizes (33pt strip, 130pt tabs, 30pt header).

3. Capture the regions with `screencapture` (interactive rectangle, no shadow):

   ```sh
   # whole window (chrome + a tiled terminal)
   screencapture -i -o tests/snapshots/electron-window-default.png
   # just the tab strip
   screencapture -i -o tests/snapshots/electron-tabbar-default.png
   # one focused terminal block (shows the 2px green border)
   screencapture -i -o tests/snapshots/electron-block-focused.png
   ```

   Use `screencapture -R<x,y,w,h>` for exact, repeatable rectangles once you know
   the coordinates (preferred over interactive capture for regressions).

4. The Electron screenshots are the human acceptance reference. To diff the native
   render *directly* against Electron, copy an `electron-*.png` over the matching
   native baseline name (e.g. `cp electron-tabbar-default.png tabbar-default.png`)
   and run the gate; expect small AA/sub-pixel differences (the default tolerance
   is 2% mean channel diff, raise per-snapshot if your capture has a title-bar
   shadow or different backing scale).

## Checklist (STYLE.md acceptance)

- Window bg `#222`; tab strip translucent-blurred at 33px; pills 130px with
  white-10% active fill and white active label.
- Terminal `default-dark` ANSI palette on `#000`, Hack 12, block cursor, no blink.
- Focused block: 2px green (`#58c142`) border; 8px radius everywhere.
- Inter in the UI; Hack in the terminal.

> Note: the blurred tab-strip backdrop (`NSVisualEffectView`) has nothing to blur
> in an offscreen render, so the native `tabbar-default.png` shows the tint only.
> Compare the **blur** against Electron visually; the automated diff covers the
> pills, labels, dividers, workspace button and the new-tab "+".
