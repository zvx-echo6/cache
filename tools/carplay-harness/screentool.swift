// A small helper for the CarPlay harness, compiled on the runner: the Mac screen's size, the windows on it, whether this
// process may post input, and a mouse click at a point (the way the CarPlay window gets its taps).
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : ""

if command == "screen" {
  let display = CGMainDisplayID()
  let bounds = CGDisplayBounds(display)
  let backing = NSScreen.main?.backingScaleFactor ?? 0
  print("screen points \(Int(bounds.width)) \(Int(bounds.height)) pixels \(CGDisplayPixelsWide(display)) \(CGDisplayPixelsHigh(display)) screens \(NSScreen.screens.count) backing \(backing)")
} else if command == "trusted" {
  print("accessibility \(AXIsProcessTrusted()) postEvents \(CGPreflightPostEventAccess()) screenCapture \(CGPreflightScreenCaptureAccess())")
} else if command == "windows" {
  let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
  let list = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
  for window in list {
    let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
    let name = window[kCGWindowName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    let number = window[kCGWindowNumber as String] as? Int ?? -1
    var rect = CGRect.zero
    if let dictionary = window[kCGWindowBounds as String] as? [String: Any],
       let parsed = CGRect(dictionaryRepresentation: dictionary as CFDictionary) {
      rect = parsed
    }
    print("win \(number) layer \(layer) \(Int(rect.origin.x)) \(Int(rect.origin.y)) \(Int(rect.width)) \(Int(rect.height)) [\(owner)] [\(name)]")
  }
} else if command == "click", arguments.count >= 4, let x = Double(arguments[2]), let y = Double(arguments[3]) {
  let point = CGPoint(x: x, y: y)
  let source = CGEventSource(stateID: .hidSystemState)
  let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
  let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
  let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
  move?.post(tap: .cghidEventTap)
  usleep(200_000)
  down?.post(tap: .cghidEventTap)
  usleep(120_000)
  up?.post(tap: .cghidEventTap)
  usleep(100_000)
  print("clicked \(x) \(y) made \(move != nil) \(down != nil) \(up != nil)")
} else {
  print("usage: screentool screen | trusted | windows | click <x> <y>")
  exit(2)
}
