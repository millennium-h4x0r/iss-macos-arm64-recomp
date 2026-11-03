import Foundation
import CoreGraphics
let t0 = Date()
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
print(String(format: "%.3f %d", Date().timeIntervalSince(t0), info?.count ?? -1))
