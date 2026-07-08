# Wave Native — Style Spec (pixel-match the Electron app)

Goal: the native client looks **identical** to Wave's default **dark** theme.
Wave is deliberately minimal; the "look" is: solid `#222` window, a translucent
blurred 33px tab strip with pill tabs, black terminal blocks with an 8px radius
and a green focus border, Inter for UI / Hack for mono, and the `default-dark`
terminal palette.

All values are literal from source (default dark only — there is no light theme).
Source files: `frontend/app/theme.scss`, `frontend/tailwindsetup.css`,
`frontend/app/tab/{tab,tabbar}.scss`, `frontend/app/tab/workspaceswitcher.scss`,
`frontend/app/block/block.scss`, `frontend/app/view/term/{term.scss,term.tsx,termutil.ts}`,
`pkg/wconfig/defaultconfig/{termthemes.json,settings.json}`, `frontend/app/app.scss`,
`emain/emain-window.ts`.

> The canonical Swift values live in `Sources/Theme.swift`. This doc is the
> human-readable source of those constants.

---

## 1. Core palette (`theme.scss:4-160`)

| Token | Value |
|---|---|
| text primary | `#f7f7f7` |
| text secondary | `rgb(195,200,194)` |
| text grey | `#666666` |
| window/main bg | `#222222` (`rgb(34,34,34)`) |
| border | `rgba(255,255,255,0.16)` |
| accent | `#58c142` (`rgb(88,193,66)`) |
| accent hover | `#76df60` (`rgb(118,223,96)`) |
| panel bg | `rgba(31,33,31,0.5)` |
| hover bg | `rgba(255,255,255,0.10)` |
| highlight bg | `rgba(255,255,255,0.20)` |
| block bg | `rgba(0,0,0,0.5)` |
| block bg solid | `#000000` |
| modal bg | `#232323` |
| modal border | `rgba(255,255,255,0.12)` |
| modal shadow | `rgba(0,0,0,0.8)` |
| error | `#e54d2e` · warning `#e0b956` · success `#4e9a06` |
| link | `#58c142` |

Scrollbar: track transparent; thumb `rgba(255,255,255,0.15)`; hover
`rgba(255,255,255,0.5)`; width/height `4px`, radius `4px`.

## 2. Fonts

| Role | Spec |
|---|---|
| UI base | **Inter** 14pt regular |
| UI mono | **Hack** 12pt |
| Header | Inter 11pt weight 700 |
| Tab label | Inter 11pt weight 500 (active 600) |
| Terminal | **Hack** 12pt, line-height 1.0, letter-spacing 0, weight normal (bold→bold), `drawBoldTextInBrightColors: false` |

Ship Inter + Hack in the app bundle (don't rely on system install).

## 3. Terminal `default-dark` (`termthemes.json:2-27`) — feed to libghostty

```
background  #000000      foreground  #c1c1c1
cursor      (foreground) selection   (system default)

ANSI        black #757575  red #cc685c  green #76c266  yellow #cbca9b
            blue  #85aacb  magenta #cc72ca  cyan #74a7cb  white #c1c1c1
ANSI bright black #727272  red #cc9d97  green #a3dd97  yellow #cbcaaa
            blue  #9ab6cb  magenta #cc8ecb  cyan #b7b8cb  white #f0f0f0
```
- Default term font size **12**, line-height **1.0**.
- Cursor: **block**, no blink (`settings.json` `term:cursor`, `term:cursorblink:false`).
- Note: the web app forces canvas bg transparent and paints `#000000` behind it;
  in libghostty just use background `#000000` directly.
- Other shipped presets (onedarkpro, dracula, monokai, campbell, warmyellow,
  rosepine) are in the same JSON if we want a theme picker later.

## 4. Tab bar / chrome (`tabbar.scss`, `tab.scss`, `workspaceswitcher.scss`)

- Strip height **33px** (zoom 1); bg `rgba(0,0,0,0.35)` + **backdrop blur 20px**;
  `padding-top 3px`; whole strip is a window-drag region **except** interactive
  children (tabs, buttons) which opt out.
- Tab: width **130px** (same active/inactive); inner = `width calc(100%-6px)`,
  radius **6px**, height ~26px. Label Inter 11px/500, color text-secondary,
  text-shadow `0 0 4px rgb(from #222 / 0.25)`, centered + ellipsis.
- Active/hover tab inner bg = white @ **10%** (`rgb(from #f7f7f7 / 0.1)`); active
  label `#ffffff` weight 600.
- Tab divider: 1px × 14px, white @ 20%; hidden next to active/hovered tab.
- Close button: 20×20, right 4px, hidden until hover; hover color text-primary.
- New-tab "+": height 22px, pad-x 8px, radius 6px, font 12px, text-secondary →
  hover text-primary on `rgba(255,255,255,0.2)`; icon `fa-plus`.
- Workspace button: height 22px, pad `0 12px`, radius 6px, gap 6px, bg white @ 10%
  → hover white @ 14%; icon 15px; name 12px/500 text-primary, max-width 160px.
  Dropdown panel: width 256px, radius 8px, shadow `0 8px 24px rgba(0,0,0,0.8)`.

> NB: the upstream strip is **33px** and traffic-light inset **74px** (80 on
> Tahoe). The `thoro-fixes` branch used 36px / 78px — for a faithful native port
> use the upstream 33/74 values (encoded in Theme.swift; adjust if you prefer the
> thoro tweaks).

## 5. Block frame (`block.scss`)

- Container radius **8px** (`--block-border-radius`). Outer padding 1px; inner bg
  `rgba(0,0,0,0.5)` radius 8px.
- Header: height **30px**, padding `4px 5px 4px 7px`, gap 8px, font Inter 11/700,
  bottom border `rgba(255,255,255,0.16)`, top corners radius 8px. View icon 14px
  @ opacity 0.5 width 16px. Header text 11px opacity 0.7.
- Content padding 5px (or 0 for no-padding views like terminal canvas which uses
  margin `5px 1px 5px 4px`).
- **Focused block**: 2px solid `#58c142` border overlay at radius 8px
  (unfocused = transparent / 10% border for preview).
- Tile gap between blocks: **3px** (`window:tilegapsize`).

## 6. Window (`emain-window.ts`, `app.scss`)

- macOS `titleBarStyle: hiddenInset` (frameless + native traffic lights, native
  rounded corners). In AppKit: borderless/full-size-content window with standard
  window buttons; the tab strip is the title-bar drag area.
- Body bg `#222222` opaque (transparency/vibrancy only if `window:transparent`,
  default false — keep solid).
- Traffic-light inset (left content start): **74px** (80 on Tahoe+).

## 7. Radii / spacing summary

- radius: large **8** (blocks, modals, dropdown), medium **6** (tabs, buttons,
  workspace btn), small **4 / 2** (inputs, scrollbar).
- tile gap **3**; header gap **8**; action gap **6**.
- modal shadow `0 8px 24px rgba(0,0,0,0.8)`.

---

## Acceptance: "looks identical"

Side-by-side the native window and the Electron app (default dark) and verify:
1. Window bg `#222`, tab strip translucent-blurred at 33px, pill tabs at 130px
   with white-10% active fill and white active label.
2. Terminal renders the `default-dark` ANSI palette on `#000`, Hack 12, block
   cursor, no blink.
3. A focused block shows the 2px green (`#58c142`) border; 8px radius everywhere.
4. Inter everywhere in the UI; Hack in the terminal.
Capture screenshots into `tests/snapshots/` and diff against the Electron app.
