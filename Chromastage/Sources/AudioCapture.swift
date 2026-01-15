import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreGraphics

enum ScreenCapturePermissionStatus: String {
  case unknown
  case granted
  case denied
}

@MainActor
final class AudioCapture: NSObject, ObservableObject {
  @Published var isCapturing = false
  @Published var statusMessage: String = ""
  @Published var permissionStatus: ScreenCapturePermissionStatus = .unknown
  @Published var needsAttention = false
  @Published var lastError: String?

  nonisolated(unsafe) private let ringBuffer = AudioRingBuffer(capacity: 16384)
  private let audioQueue = DispatchQueue(label: "Chromastage.AudioCapture")
  private var stream: SCStream?
  private var isStarting = false
  private var permissionProbeTask: Task<Void, Never>?
  private var pendingStartAfterPermission = false

  func start(requestPermission: Bool = false) async {
    if isCapturing || isStarting {
      if pendingStartAfterPermission {
        schedulePermissionProbe()
      }
      return
    }

    isStarting = true
    defer { isStarting = false }

    statusMessage = "Requesting system audio capture permission..."

    let permission = refreshPermissionStatus(requestIfNeeded: requestPermission)
    if permission != .granted {
      pendingStartAfterPermission = true
      schedulePermissionProbe()
      markCaptureIssue("Enable Screen & System Audio Recording in System Settings.")
      return
    }
    pendingStartAfterPermission = false
    stopPermissionProbe()

    do {
      let content = try await SCShareableContent.current
      guard let display = content.displays.first else {
        markCaptureIssue("No display available for capture.")
        return
      }

      let filter = SCContentFilter(display: display, excludingWindows: [])
      let config = SCStreamConfiguration()
      config.capturesAudio = true
      config.excludesCurrentProcessAudio = true
      config.sampleRate = 44_100
      config.channelCount = 2
      config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
      config.queueDepth = 8
      config.width = 2
      config.height = 2
      config.pixelFormat = kCVPixelFormatType_32BGRA

      let stream = SCStream(filter: filter, configuration: config, delegate: self)
      try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
      try await stream.startCapture()

      self.stream = stream
      isCapturing = true
      needsAttention = false
      lastError = nil
      permissionStatus = .granted
      statusMessage = "Capturing system audio (Apple Music and other audio apps)."
    } catch {
      _ = refreshPermissionStatus(requestIfNeeded: false)
      markCaptureIssue("Audio capture failed: \(error.localizedDescription)")
    }
  }

  func stop() {
    pendingStartAfterPermission = false
    stopPermissionProbe()
    guard let stream else { return }
    stream.stopCapture { [weak self] error in
      DispatchQueue.main.async {
        if let error {
          self?.statusMessage = "Stop capture failed: \(error.localizedDescription)"
        } else {
          self?.statusMessage = "Capture stopped."
        }
        self?.isCapturing = false
      }
    }
    self.stream = nil
  }

  func refreshPermissionStatus(requestIfNeeded: Bool = false) -> ScreenCapturePermissionStatus {
    if permissionStatus == .granted && !requestIfNeeded {
      return .granted
    }
    var granted = CGPreflightScreenCaptureAccess()
    if !granted, requestIfNeeded {
      granted = CGRequestScreenCaptureAccess()
    }
    let status: ScreenCapturePermissionStatus = granted ? .granted : .denied
    permissionStatus = status
    if granted {
      if !pendingStartAfterPermission && !isStarting {
        stopPermissionProbe()
      }
    } else if pendingStartAfterPermission {
      schedulePermissionProbe()
      Task { @MainActor in
        await self.probeShareableContentAccess()
      }
    }
    return status
  }

  func requestPermission() -> Bool {
    pendingStartAfterPermission = true
    let granted = CGRequestScreenCaptureAccess()
    permissionStatus = granted ? .granted : .denied
    if granted {
      pendingStartAfterPermission = false
      stopPermissionProbe()
    } else {
      schedulePermissionProbe()
    }
    return granted
  }

  private func markCaptureIssue(_ message: String) {
    statusMessage = message
    lastError = message
    needsAttention = true
    isCapturing = false
    stream = nil
  }

  private func schedulePermissionProbe() {
    guard permissionProbeTask == nil else { return }
    permissionProbeTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        var status = self.refreshPermissionStatus(requestIfNeeded: false)
        if status != .granted {
          status = await self.probeShareableContentAccess()
        }
        if status == .granted {
          if self.isStarting {
            continue
          }
          self.permissionProbeTask = nil
          if self.pendingStartAfterPermission && !self.isCapturing {
            self.pendingStartAfterPermission = false
            await self.start()
          }
          return
        }
      }
    }
  }

  private func stopPermissionProbe() {
    permissionProbeTask?.cancel()
    permissionProbeTask = nil
  }

  @MainActor
  @discardableResult
  private func probeShareableContentAccess() async -> ScreenCapturePermissionStatus {
    guard permissionStatus != .granted else { return .granted }
    do {
      let content = try await SCShareableContent.current
      if !content.displays.isEmpty {
        permissionStatus = .granted
        stopPermissionProbe()
        return .granted
      }
    } catch {
      // Ignore; permission likely still denied.
    }
    return permissionStatus
  }

  nonisolated func latestAudioBytes(count: Int) -> (mono: Data, left: Data, right: Data) {
    let (leftSamples, rightSamples) = ringBuffer.snapshot(count: count)
    var monoBytes = [UInt8](repeating: 128, count: count)
    var leftBytes = [UInt8](repeating: 128, count: count)
    var rightBytes = [UInt8](repeating: 128, count: count)

    for i in 0..<count {
      let left = leftSamples[i]
      let right = rightSamples[i]
      leftBytes[i] = Self.floatToByte(left)
      rightBytes[i] = Self.floatToByte(right)
      monoBytes[i] = Self.floatToByte((left + right) * 0.5)
    }

    return (Data(monoBytes), Data(leftBytes), Data(rightBytes))
  }

  nonisolated func latestSamples(count: Int) -> (left: [Float], right: [Float]) {
    ringBuffer.snapshot(count: count)
  }

  nonisolated private static func floatToByte(_ sample: Float) -> UInt8 {
    let clamped = max(-1.0, min(1.0, sample))
    let scaled = (clamped * 127.0) + 128.0
    let rounded = Int(scaled.rounded())
    return UInt8(max(0, min(255, rounded)))
  }
}

extension AudioCapture: SCStreamOutput, SCStreamDelegate {
  nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .audio else { return }
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
      return
    }

    let channelCount = Int(asbd.pointee.mChannelsPerFrame)
    if channelCount == 0 {
      return
    }

    let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let isNonInterleaved = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)

    var blockBuffer: CMBlockBuffer?
    var bufferListSizeNeeded: Int = 0
    _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &bufferListSizeNeeded,
      bufferListOut: nil,
      bufferListSize: 0,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: 0,
      blockBufferOut: &blockBuffer
    )

    if bufferListSizeNeeded == 0 { return }

    let bufferListRaw = UnsafeMutableRawPointer.allocate(
      byteCount: bufferListSizeNeeded,
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { bufferListRaw.deallocate() }

    let audioBufferList = bufferListRaw.bindMemory(to: AudioBufferList.self, capacity: 1)

    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: audioBufferList,
      bufferListSize: bufferListSizeNeeded,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: 0,
      blockBufferOut: &blockBuffer
    )

    if status != noErr {
      return
    }

    let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
    guard bufferList.count > 0 else { return }

    if isNonInterleaved, bufferList.count >= 2 {
      let leftBuffer = bufferList[0]
      let rightBuffer = bufferList[1]

      if isFloat {
        let leftPtr = leftBuffer.mData!.assumingMemoryBound(to: Float.self)
        let rightPtr = rightBuffer.mData!.assumingMemoryBound(to: Float.self)
        ringBuffer.appendInterleaved(leftPtr: leftPtr, rightPtr: rightPtr, frameCount: frameCount)
      } else {
        let leftPtr = leftBuffer.mData!.assumingMemoryBound(to: Int16.self)
        let rightPtr = rightBuffer.mData!.assumingMemoryBound(to: Int16.self)
        ringBuffer.appendInterleavedInt16(leftPtr: leftPtr, rightPtr: rightPtr, frameCount: frameCount)
      }
      return
    }

    let buffer = bufferList[0]
    if isFloat {
      let samplePtr = buffer.mData!.assumingMemoryBound(to: Float.self)
      ringBuffer.appendInterleaved(samplePtr: samplePtr, frameCount: frameCount, channels: channelCount)
    } else {
      let samplePtr = buffer.mData!.assumingMemoryBound(to: Int16.self)
      ringBuffer.appendInterleavedInt16(samplePtr: samplePtr, frameCount: frameCount, channels: channelCount)
    }
  }

  nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
    DispatchQueue.main.async { [weak self] in
      self?.markCaptureIssue("Capture stopped: \(error.localizedDescription)")
    }
  }
}

final class AudioRingBuffer {
  private let capacity: Int
  private var left: [Float]
  private var right: [Float]
  private var writeIndex = 0
  private let queue = DispatchQueue(label: "Chromastage.AudioRingBuffer")

  init(capacity: Int) {
    self.capacity = capacity
    self.left = Array(repeating: 0, count: capacity)
    self.right = Array(repeating: 0, count: capacity)
  }

  func appendInterleaved(samplePtr: UnsafePointer<Float>, frameCount: Int, channels: Int) {
    guard channels > 0 else { return }
    queue.sync {
      for i in 0..<frameCount {
        let base = i * channels
        let l = samplePtr[base]
        let r = channels > 1 ? samplePtr[base + 1] : l
        write(left: l, right: r)
      }
    }
  }

  func appendInterleavedInt16(samplePtr: UnsafePointer<Int16>, frameCount: Int, channels: Int) {
    guard channels > 0 else { return }
    let scale = Float(1.0 / 32768.0)
    queue.sync {
      for i in 0..<frameCount {
        let base = i * channels
        let l = Float(samplePtr[base]) * scale
        let r = channels > 1 ? Float(samplePtr[base + 1]) * scale : l
        write(left: l, right: r)
      }
    }
  }

  func appendInterleaved(leftPtr: UnsafePointer<Float>, rightPtr: UnsafePointer<Float>, frameCount: Int) {
    queue.sync {
      for i in 0..<frameCount {
        write(left: leftPtr[i], right: rightPtr[i])
      }
    }
  }

  func appendInterleavedInt16(leftPtr: UnsafePointer<Int16>, rightPtr: UnsafePointer<Int16>, frameCount: Int) {
    let scale = Float(1.0 / 32768.0)
    queue.sync {
      for i in 0..<frameCount {
        write(left: Float(leftPtr[i]) * scale, right: Float(rightPtr[i]) * scale)
      }
    }
  }

  private func write(left l: Float, right r: Float) {
    left[writeIndex] = l
    right[writeIndex] = r
    writeIndex = (writeIndex + 1) % capacity
  }

  func snapshot(count: Int) -> ([Float], [Float]) {
    let count = min(count, capacity)
    var leftCopy = [Float](repeating: 0, count: count)
    var rightCopy = [Float](repeating: 0, count: count)

    queue.sync {
      var idx = writeIndex - count
      if idx < 0 { idx += capacity }
      for i in 0..<count {
        leftCopy[i] = left[idx]
        rightCopy[i] = right[idx]
        idx = (idx + 1) % capacity
      }
    }

    return (leftCopy, rightCopy)
  }
}
