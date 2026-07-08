// CGhostty — Swift binding to Ghostty's headless terminal core, libghostty-vt.
//
// libghostty-vt owns VT escape-sequence parsing, terminal/grid/scrollback state,
// and key encoding. WaveTerminal feeds it the reconciled byte stream (PROTOCOL.md
// §4) via `ghostty_terminal_vt_write`, reads the grid for rendering via the
// render-state API (`ghostty/vt/render.h`), and ships query responses (DSR/DA)
// back to the pty through the write-pty callback.
//
// Build/link (docs/INTEGRATION.md §1, scripts/build-deps.sh):
//   -Xcc     -Ivendor/libghostty/include      (resolve <ghostty/vt.h>)
//   -Xlinker -Lvendor/libghostty/lib -lghostty-vt
//
// GHOSTTY_STATIC makes GHOSTTY_API a no-op so the symbols bind against the static
// archive (libghostty-vt.a) with default visibility.

#ifndef WAVE_GHOSTTY_SHIM_H
#define WAVE_GHOSTTY_SHIM_H

#define GHOSTTY_STATIC 1
#include <ghostty/vt.h>

#endif /* WAVE_GHOSTTY_SHIM_H */
