// Prints the on-screen windows of a process, one per line: id, then title.
// Usage: windows <pid>
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1]) ?? 0
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == pid
    && (window[kCGWindowLayer as String] as? Int) == 0 {
    print("\(window[kCGWindowNumber as String] ?? 0)\t\(window[kCGWindowName as String] ?? "")")
}
