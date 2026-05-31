import Cocoa
import FlutterMacOS
import Network

final class LocalScreenShareController {
  static let shared = LocalScreenShareController()

  private let capture = ScreenCaptureService()
  private lazy var server = LocalMJPEGServer(frameProvider: { [weak self] in
    self?.capture.latestJPEG
  })

  private var statusMessage = "Ready"
  private let port: UInt16 = 41873

  private init() {}

  var isSharing: Bool {
    server.isRunning && capture.isRunning
  }

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "local_screen_share/native",
      binaryMessenger: messenger
    )

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }

      switch call.method {
      case "getLocalIP":
        result(self.localIPAddress() ?? "127.0.0.1")
      case "startSharing":
        let args = call.arguments as? [String: Any]
        let password = (args?["password"] as? String) ?? ""
        self.startSharing(password: password, result: result)
      case "stopSharing":
        self.stopSharing(result: result)
      case "getStatus":
        result(self.statusPayload())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func startSharing(password: String, result: @escaping FlutterResult) {
    if isSharing {
      result(statusPayload(message: "Already sharing"))
      return
    }

    Task {
      do {
        try await capture.start()
        try server.start(port: port, password: password)
        statusMessage = "Sharing at \(viewerURL)"
        let payload = statusPayload()
        DispatchQueue.main.async {
          result(payload)
        }
      } catch {
        capture.stop()
        server.stop()
        statusMessage = error.localizedDescription
        let message = error.localizedDescription
        DispatchQueue.main.async {
          result(FlutterError(
            code: "START_FAILED",
            message: message,
            details: nil
          ))
        }
      }
    }
  }

  private func stopSharing(result: FlutterResult) {
    capture.stop()
    server.stop()
    statusMessage = "Stopped"
    result(statusPayload())
  }

  private var viewerURL: String {
    "http://\(localIPAddress() ?? "127.0.0.1"):\(port)"
  }

  private func statusPayload(message: String? = nil) -> [String: Any] {
    [
      "isSharing": isSharing,
      "message": message ?? statusMessage,
      "url": viewerURL,
      "port": port
    ]
  }

  private func localIPAddress() -> String? {
    var address: String?
    var interfaces: UnsafeMutablePointer<ifaddrs>?

    guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
      return nil
    }

    defer { freeifaddrs(interfaces) }

    for pointer in sequence(first: firstInterface, next: { $0.pointee.ifa_next }) {
      let interface = pointer.pointee
      let flags = Int32(interface.ifa_flags)
      let isUp = (flags & IFF_UP) == IFF_UP
      let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK

      guard let socketAddress = interface.ifa_addr,
            isUp,
            !isLoopback,
            socketAddress.pointee.sa_family == UInt8(AF_INET) else {
        continue
      }

      let name = String(cString: interface.ifa_name)
      guard name == "en0" || name == "en1" || name.hasPrefix("bridge") else {
        continue
      }

      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let result = getnameinfo(
        socketAddress,
        socklen_t(socketAddress.pointee.sa_len),
        &hostname,
        socklen_t(hostname.count),
        nil,
        0,
        NI_NUMERICHOST
      )

      if result == 0 {
        let candidate = String(cString: hostname)
        if isPrivateIPv4(candidate) {
          address = candidate
          break
        }
      }
    }

    return address
  }

  private func isPrivateIPv4(_ ip: String) -> Bool {
    if ip == "127.0.0.1" { return true }
    if ip.hasPrefix("10.") || ip.hasPrefix("192.168.") || ip.hasPrefix("169.254.") {
      return true
    }

    let parts = ip.split(separator: ".").compactMap { Int($0) }
    if parts.count == 4, parts[0] == 172, (16...31).contains(parts[1]) {
      return true
    }

    return false
  }
}
