#!/bin/bash
# 截 Agent IDEA 自己的窗口（按窗口 ID，不需要把它切到前台、不打扰正在用电脑的人）。
# 用法：scripts/snapshot_window.sh out.png
set -euo pipefail
OUT="${1:-agentidea-window.png}"
WID=$(swift - <<'SWIFT'
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for window in list {
  guard let owner = window[kCGWindowOwnerName as String] as? String, (owner == "AgentIDEA" || owner == "Agent IDEA"),
        let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
        let id = window[kCGWindowNumber as String] as? Int,
        let onScreen = window[kCGWindowIsOnscreen as String] as? Bool, onScreen,
        let bounds = window[kCGWindowBounds as String] as? [String: Any], (bounds["Height"] as? Double ?? 0) > 200 else { continue }
  print(id)
  break
}
SWIFT
)
[ -n "$WID" ] || { echo "没找到 AgentIDEA 的窗口" >&2; exit 1; }
screencapture -x -o -l "$WID" "$OUT"
echo "$OUT"
