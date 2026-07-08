// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// winlist.swift — list on-screen windows for an owner (default "WaveApp") with their
// CGWindowID + bounds, so scripts can capture a SPECIFIC window by id:
//
//   id=$(swift scripts/winlist.swift WaveApp | head -1 | cut -d' ' -f1)
//   screencapture -l$id -o /tmp/win.png      # true window pixels incl. corner mask
//
// Output (frontmost first): "<id> pid=<pid> <x>,<y> <w>x<h> <title>"
// The pid lets callers pick a SPECIFIC app instance (e.g. a drive.sh test instance,
// whose pid is in its .driveapp.pid) when several share the "Wave Native" owner name.

import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "WaveApp"
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let infos = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write("no window info\n".data(using: .utf8)!)
    exit(1)
}

for info in infos {
    guard let name = info[kCGWindowOwnerName as String] as? String, name == owner else { continue }
    guard let id = info[kCGWindowNumber as String] as? Int else { continue }
    guard let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    let layer = info[kCGWindowLayer as String] as? Int ?? 0
    if layer != 0 { continue }  // normal windows only (skip menus/overlays)
    let pid = info[kCGWindowOwnerPID as String] as? Int ?? 0
    let x = Int(b["X"] ?? 0), y = Int(b["Y"] ?? 0)
    let w = Int(b["Width"] ?? 0), h = Int(b["Height"] ?? 0)
    let title = info[kCGWindowName as String] as? String ?? ""
    print("\(id) pid=\(pid) \(x),\(y) \(w)x\(h) \(title)")
}
