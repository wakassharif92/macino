import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import ScreenCaptureKit

enum ScreenCaptureServiceError: LocalizedError {
  case unsupportedOS
  case permissionDenied
  case noDisplay
  case noFrame

  var errorDescription: String? {
    switch self {
    case .unsupportedOS:
      return "ScreenCaptureKit requires macOS 12.3 or newer."
    case .permissionDenied:
      return "Screen Recording permission is required. Enable it in System Settings, then restart the app."
    case .noDisplay:
      return "Could not find a display to capture."
    case .noFrame:
      return "Screen capture started, but no frame has arrived yet."
    }
  }
}

final class ScreenCaptureService: NSObject {
  private let frameQueue = DispatchQueue(label: "local.screen.share.frames")
  private let stateQueue = DispatchQueue(label: "local.screen.share.capture.state")
  private let ciContext = CIContext()

  private var stream: SCStream?
  private var lastJPEG: Data?
  private(set) var isRunning = false

  var latestJPEG: Data? {
    stateQueue.sync { lastJPEG }
  }

  func start() async throws {
    guard #available(macOS 12.3, *) else {
      throw ScreenCaptureServiceError.unsupportedOS
    }

    guard hasScreenRecordingPermission() else {
      requestScreenRecordingPermission()
      throw ScreenCaptureServiceError.permissionDenied
    }

    if isRunning { return }

    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: true
    )

    guard let display = content.displays.first else {
      throw ScreenCaptureServiceError.noDisplay
    }

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.width = min(display.width, 1920)
    configuration.height = min(display.height, 1080)
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 12)
    configuration.queueDepth = 3
    configuration.showsCursor = true
    configuration.pixelFormat = kCVPixelFormatType_32BGRA

    let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
    try await stream.startCapture()

    self.stream = stream
    isRunning = true
  }

  func stop() {
    guard let stream else {
      isRunning = false
      return
    }

    stream.stopCapture { _ in }
    self.stream = nil
    isRunning = false
    stateQueue.async {
      self.lastJPEG = nil
    }
  }

  private func hasScreenRecordingPermission() -> Bool {
    CGPreflightScreenCaptureAccess()
  }

  private func requestScreenRecordingPermission() {
    CGRequestScreenCaptureAccess()
  }

  private func updateLatestJPEG(from sampleBuffer: CMSampleBuffer) {
    guard CMSampleBufferIsValid(sampleBuffer),
          let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return
    }

    let image = CIImage(cvPixelBuffer: pixelBuffer)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let jpeg = ciContext.jpegRepresentation(
      of: image,
      colorSpace: colorSpace,
      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.58]
    ) else {
      return
    }

    stateQueue.async {
      self.lastJPEG = jpeg
    }
  }
}

@available(macOS 12.3, *)
extension ScreenCaptureService: SCStreamOutput {
  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .screen else { return }
    updateLatestJPEG(from: sampleBuffer)
  }
}
