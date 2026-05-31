import ApplicationServices
import AppKit
import Foundation

enum RemoteControlServiceError: LocalizedError {
  case accessibilityPermissionRequired
  case invalidEvent

  var errorDescription: String? {
    switch self {
    case .accessibilityPermissionRequired:
      return "Accessibility permission is required for remote mouse and keyboard control."
    case .invalidEvent:
      return "Invalid remote control event."
    }
  }
}

final class RemoteControlService {
  private let queue = DispatchQueue(label: "local.screen.share.remote-control")
  private let source = CGEventSource(stateID: .hidSystemState)

  var isTrusted: Bool {
    AXIsProcessTrusted()
  }

  func requestPermissionIfNeeded() -> Bool {
    if isTrusted { return true }

    let options = [
      kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true
    ] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
  }

  func handle(_ event: [String: Any]) throws {
    guard isTrusted else {
      throw RemoteControlServiceError.accessibilityPermissionRequired
    }

    queue.async {
      self.dispatch(event)
    }
  }

  private func dispatch(_ event: [String: Any]) {
    guard let type = event["type"] as? String else { return }

    switch type {
    case "mouseMove":
      guard let point = point(from: event) else { return }
      CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    case "mouseDown":
      postMouse(event, down: true)
    case "mouseUp":
      postMouse(event, down: false)
    case "wheel":
      let deltaY = event["deltaY"] as? Double ?? 0
      CGEvent(
        scrollWheelEvent2Source: source,
        units: .pixel,
        wheelCount: 1,
        wheel1: Int32(-deltaY),
        wheel2: 0,
        wheel3: 0
      )?.post(tap: .cghidEventTap)
    case "keyDown":
      postKey(event, down: true)
    case "keyUp":
      postKey(event, down: false)
    default:
      return
    }
  }

  private func postMouse(_ event: [String: Any], down: Bool) {
    guard let point = point(from: event) else { return }
    let buttonNumber = event["button"] as? Int ?? 0
    let button = mouseButton(buttonNumber)
    let eventType: CGEventType

    switch (button, down) {
    case (.left, true):
      eventType = .leftMouseDown
    case (.left, false):
      eventType = .leftMouseUp
    case (.right, true):
      eventType = .rightMouseDown
    case (.right, false):
      eventType = .rightMouseUp
    default:
      eventType = down ? .otherMouseDown : .otherMouseUp
    }

    CGEvent(mouseEventSource: source, mouseType: eventType, mouseCursorPosition: point, mouseButton: button)?
      .post(tap: .cghidEventTap)
  }

  private func postKey(_ event: [String: Any], down: Bool) {
    guard let code = event["code"] as? String,
          let keyCode = keyCode(for: code) else {
      return
    }

    let keyEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
    keyEvent?.flags = flags(from: event)
    keyEvent?.post(tap: .cghidEventTap)
  }

  private func point(from event: [String: Any]) -> CGPoint? {
    guard let normalizedX = event["x"] as? Double,
          let normalizedY = event["y"] as? Double else {
      return nil
    }

    let frame = CGDisplayBounds(CGMainDisplayID())
    let x = frame.minX + (frame.width * CGFloat(max(0, min(1, normalizedX))))
    let y = frame.minY + (frame.height * CGFloat(max(0, min(1, normalizedY))))
    return CGPoint(x: x, y: y)
  }

  private func mouseButton(_ value: Int) -> CGMouseButton {
    switch value {
    case 2:
      return .right
    case 1:
      return .center
    default:
      return .left
    }
  }

  private func flags(from event: [String: Any]) -> CGEventFlags {
    var flags = CGEventFlags()
    if event["shiftKey"] as? Bool == true { flags.insert(.maskShift) }
    if event["ctrlKey"] as? Bool == true { flags.insert(.maskControl) }
    if event["altKey"] as? Bool == true { flags.insert(.maskAlternate) }
    if event["metaKey"] as? Bool == true { flags.insert(.maskCommand) }
    return flags
  }

  private func keyCode(for code: String) -> CGKeyCode? {
    let map: [String: CGKeyCode] = [
      "KeyA": 0, "KeyS": 1, "KeyD": 2, "KeyF": 3, "KeyH": 4, "KeyG": 5,
      "KeyZ": 6, "KeyX": 7, "KeyC": 8, "KeyV": 9, "KeyB": 11, "KeyQ": 12,
      "KeyW": 13, "KeyE": 14, "KeyR": 15, "KeyY": 16, "KeyT": 17,
      "Digit1": 18, "Digit2": 19, "Digit3": 20, "Digit4": 21, "Digit6": 22,
      "Digit5": 23, "Equal": 24, "Digit9": 25, "Digit7": 26, "Minus": 27,
      "Digit8": 28, "Digit0": 29, "BracketRight": 30, "KeyO": 31,
      "KeyU": 32, "BracketLeft": 33, "KeyI": 34, "KeyP": 35, "Enter": 36,
      "KeyL": 37, "KeyJ": 38, "Quote": 39, "KeyK": 40, "Semicolon": 41,
      "Backslash": 42, "Comma": 43, "Slash": 44, "KeyN": 45, "KeyM": 46,
      "Period": 47, "Tab": 48, "Space": 49, "Backquote": 50,
      "Backspace": 51, "Escape": 53, "ArrowLeft": 123, "ArrowRight": 124,
      "ArrowDown": 125, "ArrowUp": 126
    ]

    return map[code]
  }
}
