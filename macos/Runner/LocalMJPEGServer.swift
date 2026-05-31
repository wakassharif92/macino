import Foundation
import Network

enum LocalMJPEGServerError: LocalizedError {
  case invalidPort
  case listenerFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidPort:
      return "Port 41873 is not available."
    case .listenerFailed(let reason):
      return "Local server failed: \(reason)"
    }
  }
}

final class LocalMJPEGServer {
  private let frameProvider: () -> Data?
  private let queue = DispatchQueue(label: "local.screen.share.http")
  private var listener: NWListener?
  private var password = ""
  private var connections: [ObjectIdentifier: NWConnection] = [:]

  var isRunning: Bool {
    listener != nil
  }

  init(frameProvider: @escaping () -> Data?) {
    self.frameProvider = frameProvider
  }

  func start(port: UInt16, password: String) throws {
    if isRunning { return }
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
      throw LocalMJPEGServerError.invalidPort
    }

    self.password = password

    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true

    let listener = try NWListener(using: parameters, on: nwPort)
    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.stateUpdateHandler = { state in
      if case .failed(let error) = state {
        print("LocalMJPEGServer listener failed: \(error)")
      }
    }
    listener.start(queue: queue)
    self.listener = listener
  }

  func stop() {
    listener?.cancel()
    listener = nil
    connections.values.forEach { $0.cancel() }
    connections.removeAll()
  }

  private func accept(_ connection: NWConnection) {
    guard isAllowedPrivateClient(connection.endpoint) else {
      connection.cancel()
      return
    }

    connections[ObjectIdentifier(connection)] = connection
    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else { return }
      if case .cancelled = state {
        self.connections.removeValue(forKey: ObjectIdentifier(connection))
      }
      if case .failed = state {
        self.connections.removeValue(forKey: ObjectIdentifier(connection))
      }
    }
    connection.start(queue: queue)
    readRequest(from: connection)
  }

  private func readRequest(from connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
      guard let self else { return }
      if error != nil {
        connection.cancel()
        return
      }

      guard let data, let request = String(data: data, encoding: .utf8) else {
        self.sendResponse(
          connection,
          status: "400 Bad Request",
          contentType: "text/plain",
          body: Data("Bad request".utf8)
        )
        return
      }

      self.route(request: request, connection: connection)
    }
  }

  private func route(request: String, connection: NWConnection) {
    let firstLine = request.components(separatedBy: "\r\n").first ?? ""
    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2 else {
      sendResponse(connection, status: "400 Bad Request", contentType: "text/plain", body: Data("Bad request".utf8))
      return
    }

    let target = String(parts[1])
    let path = target.components(separatedBy: "?").first ?? "/"

    switch path {
    case "/":
      sendResponse(connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: Data(viewerHTML.utf8))
    case "/stream":
      guard isAuthorized(target: target) else {
        sendResponse(connection, status: "401 Unauthorized", contentType: "text/plain", body: Data("Unauthorized".utf8))
        return
      }
      sendMJPEGStream(to: connection)
    default:
      sendResponse(connection, status: "404 Not Found", contentType: "text/plain", body: Data("Not found".utf8))
    }
  }

  private func sendResponse(
    _ connection: NWConnection,
    status: String,
    contentType: String,
    body: Data
  ) {
    var headers = "HTTP/1.1 \(status)\r\n"
    headers += "Content-Type: \(contentType)\r\n"
    headers += "Content-Length: \(body.count)\r\n"
    headers += "Cache-Control: no-store\r\n"
    headers += "Connection: close\r\n\r\n"

    var response = Data(headers.utf8)
    response.append(body)
    connection.send(content: response, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  private func sendMJPEGStream(to connection: NWConnection) {
    let headers = """
    HTTP/1.1 200 OK\r
    Content-Type: multipart/x-mixed-replace; boundary=frame\r
    Cache-Control: no-store\r
    Pragma: no-cache\r
    Connection: close\r
    \r

    """

    connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self, weak connection] error in
      guard let self, let connection, error == nil else { return }
      self.sendNextFrame(to: connection)
    })
  }

  private func sendNextFrame(to connection: NWConnection) {
    guard let jpeg = frameProvider() else {
      queue.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self, weak connection] in
        guard let self, let connection else { return }
        self.sendNextFrame(to: connection)
      }
      return
    }

    var part = Data()
    part.append(Data("--frame\r\n".utf8))
    part.append(Data("Content-Type: image/jpeg\r\n".utf8))
    part.append(Data("Content-Length: \(jpeg.count)\r\n\r\n".utf8))
    part.append(jpeg)
    part.append(Data("\r\n".utf8))

    connection.send(content: part, completion: .contentProcessed { [weak self, weak connection] error in
      guard let self, let connection, error == nil else {
        connection?.cancel()
        return
      }

      self.queue.asyncAfter(deadline: .now() + .milliseconds(85)) {
        self.sendNextFrame(to: connection)
      }
    })
  }

  private func isAuthorized(target: String) -> Bool {
    guard !password.isEmpty else { return true }
    guard let query = target.components(separatedBy: "?").dropFirst().first else {
      return false
    }

    let items = query.split(separator: "&").map { pair -> (String, String) in
      let fields = pair.split(separator: "=", maxSplits: 1).map(String.init)
      let key = fields.first?.removingPercentEncoding ?? ""
      let value = fields.dropFirst().first?.removingPercentEncoding ?? ""
      return (key, value)
    }

    return items.contains { key, value in
      key == "password" && value == password
    }
  }

  private func isAllowedPrivateClient(_ endpoint: NWEndpoint) -> Bool {
    guard case .hostPort(let host, _) = endpoint else { return false }

    switch host {
    case .name(let name, _):
      return name == "localhost"
    case .ipv4(let address):
      return isAllowedPrivateIPv4(String(describing: address))
    case .ipv6(let address):
      return String(describing: address) == "::1"
    @unknown default:
      return false
    }
  }

  private func isAllowedPrivateIPv4(_ value: String) -> Bool {
    if value == "127.0.0.1" {
      return true
    }
    if value.hasPrefix("10.") || value.hasPrefix("192.168.") || value.hasPrefix("169.254.") {
      return true
    }

    let parts = value.split(separator: ".").compactMap { Int($0) }
    if parts.count == 4, parts[0] == 172, (16...31).contains(parts[1]) {
      return true
    }

    return false
  }

  private var viewerHTML: String {
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Macino</title>
      <style>
        :root { color-scheme: dark; }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          min-height: 100vh;
          background: #111816;
          color: #f4f7f3;
          font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        }
        header {
          display: flex;
          align-items: center;
          gap: 12px;
          padding: 12px 16px;
          background: #1b2522;
          border-bottom: 1px solid #34413d;
        }
        input, button {
          height: 34px;
          border-radius: 6px;
          border: 1px solid #50615c;
          background: #0f1513;
          color: #f4f7f3;
          padding: 0 10px;
        }
        button {
          cursor: pointer;
          background: #0e7c66;
          border-color: #0e7c66;
          font-weight: 700;
        }
        main {
          min-height: calc(100vh - 59px);
          display: grid;
          place-items: center;
          overflow: auto;
        }
        img {
          display: block;
          max-width: 100vw;
          max-height: calc(100vh - 59px);
          width: auto;
          height: auto;
          object-fit: contain;
        }
        .status { margin-left: auto; color: #b8c6c1; font-size: 14px; }
      </style>
    </head>
    <body>
      <header>
        <strong>Macino</strong>
        <input id="password" type="password" placeholder="Password">
        <button id="connect">Connect</button>
        <span id="status" class="status">Idle</span>
      </header>
      <main>
        <img id="screen" alt="Shared Mac screen">
      </main>
      <script>
        const img = document.getElementById('screen');
        const status = document.getElementById('status');
        const password = document.getElementById('password');
        const connect = document.getElementById('connect');

        function start() {
          const token = encodeURIComponent(password.value);
          img.src = '/stream?password=' + token + '&t=' + Date.now();
          status.textContent = 'Connected';
        }

        connect.addEventListener('click', start);
        password.addEventListener('keydown', event => {
          if (event.key === 'Enter') start();
        });
        img.addEventListener('error', () => {
          status.textContent = 'Waiting or unauthorized';
        });
        start();
      </script>
    </body>
    </html>
    """
  }
}

// Upgrade path: keep this HTTP server for setup/status, then add a WebRTC
// signaling endpoint and feed ScreenCaptureKit frames into VideoToolbox H.264.
