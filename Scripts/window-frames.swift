// Usage: swift Scripts/window-frames.swift "Token Menu Bar"
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.dropFirst().first ?? "Token Menu Bar"
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
let matches = windows.compactMap { window -> [String: Any]? in
  guard window[kCGWindowOwnerName as String] as? String == owner,
    let bounds = window[kCGWindowBounds as String] as? [String: Any]
  else { return nil }
  return [
    "id": window[kCGWindowNumber as String] as? Int ?? 0,
    "name": window[kCGWindowName as String] as? String ?? "",
    "layer": window[kCGWindowLayer as String] as? Int ?? 0,
    "x": bounds["X"] ?? 0, "y": bounds["Y"] ?? 0, "width": bounds["Width"] ?? 0, "height": bounds["Height"] ?? 0,
  ]
}
let data = try JSONSerialization.data(withJSONObject: matches, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
